require 'tensor_stream/evaluator/operation_helpers/random_gaussian'
require 'tensor_stream/evaluator/operation_helpers/array_ops_helper'
require 'tensor_stream/evaluator/operation_helpers/math_helper'
require 'tensor_stream/evaluator/opencl_buffer'
require 'distribution'
require 'opencl_ruby_ffi'
require 'narray_ffi'

module TensorStream
  module Evaluator
    class FullEvalNotPossible < RuntimeError
    end

    # Errors during graph evaluation
    class EvaluatorExcecutionException < RuntimeError
      attr_reader :tensor

      def initialize(exception, tensor)
        @exception = exception
        @tensor = tensor
      end

      def wrapped_exception
        @exception
      end
    end

    ## PURE ruby evaluator used for testing and development
    class OpenclEvaluator
      KERNELS = %w[add sub mul cast sin].freeze

      attr_accessor :retain

      include TensorStream::OpHelper
      include TensorStream::ArrayOpsHelper
      include TensorStream::MathHelper

      def initialize(session, context, thread_pool: nil, log_intermediates: false)
        @session = session
        @context = context
        @log_intermediates = log_intermediates
        @retain = context[:retain] || []
        @thread_pool = thread_pool || Concurrent::ImmediateExecutor.new

        @context[:compute_history] = [] if log_intermediates
      end

      # opencl evaluator main entrypoint
      def run(tensor, execution_context)
        _create_opencl_context
        # _prepare_kernels

        read_final_result(complete_eval(tensor, execution_context))
      end

      def complete_eval(tensor, context)
        create_command_queue
        buffer = _run(tensor, context)
        if buffer.is_a?(Array)
          buffer = buffer.collect do |b|
            next b if b.buffer.size.zero?
            _opencl_queue.enqueue_read_buffer(b.cl_buffer, b.buffer, event_wait_list: [b.op].compact)
            b
          end
        else
          return buffer if buffer.nil? || buffer.buffer.size.zero?
          _opencl_queue.enqueue_read_buffer(buffer.cl_buffer, buffer.buffer, event_wait_list: [buffer.op].compact)
        end

        _opencl_queue.finish
        buffer
      end

      protected

      # read result from opencl and convert to ruby
      def read_final_result(buffer)
        return buffer.map { |b| read_final_result(b) } if buffer.is_a?(Array)
        return nil if buffer.nil?

        buffer.to_ruby
      end

      def _create_opencl_context
        @context[:_cache][:_opencl_device] ||= begin
          platform = OpenCL::platforms.first
          platform.devices.first
        end
        @context[:_cache][:_opencl_context] ||= OpenCL::create_context(_opencl_device)
      end

      def create_command_queue
        @context[:_cache][:_opencl_queue] ||= _opencl_context.create_command_queue(_opencl_device, :properties => [ OpenCL::CommandQueue::PROFILING_ENABLE])
      end

      def _opencl_context
        @context[:_cache][:_opencl_context]
      end

      def _opencl_device
        @context[:_cache][:_opencl_device]
      end

      def _opencl_queue
        @context[:_cache][:_opencl_queue]
      end

      def _cl_program(kernel)
        @context[:_cache]["_opencl_kernel_#{kernel}"] ||= begin
          source = File.read(File.join(File.dirname(__FILE__), 'kernels', "#{kernel}.cl"))
          program = _opencl_context.create_program_with_source(source)
          program.build
        rescue OpenCL::Error::BUILD_PROGRAM_FAILURE => e
          puts "OpenCL Compile error: #{program.build_log}"
          raise e
        end
      end

      def _run(tensor, execution_context)
        return tensor if tensor.is_a?(OpenCLBuffer)
        return tensor.map { |t| _run(t, execution_context) } if tensor.is_a?(Array)

        return tensor if retain.include?(tensor) # if var is in retain don't eval to value

        tensor = tensor.call if tensor.is_a?(Proc)

        child_context = execution_context.dup
        res = if tensor.is_a?(Operation)
                eval_operation(tensor, child_context)
              elsif tensor.is_a?(Variable)
                eval_variable(tensor, child_context)
              elsif tensor.is_a?(Placeholder)
                resolve_placeholder(tensor, child_context)
              else
                eval_tensor(tensor, child_context)
              end
        execution_context.deep_merge!(returns: child_context[:returns])
        res
      end

      def eval_variable(tensor, child_context)

        if tensor.value.nil? && (tensor.buffer.nil? || !tensor.buffer.dirty)
          raise "variable #{tensor.name} not initalized"
        end

        if tensor.buffer.nil?
          tensor.buffer = wrap_opencl(tensor, name: tensor.name)
        end
        tensor.buffer
      end

      def eval_operation(tensor, child_context)
        return @context[tensor.name] if @context.key?(tensor.name)

        a = resolve_placeholder(tensor.items[0], child_context) if tensor.items && tensor.items[0]
        b = resolve_placeholder(tensor.items[1], child_context) if tensor.items && tensor.items[1]

        case tensor.operation
        when :identity
          _run(a, child_context)
        when :assign
          assign_var(tensor, b, child_context)
        when :assign_add
          a = _run(a, child_context)
          b = _run(b, child_context)

          value = execute_2_operand_func('add', tensor, a, b, child_context)
          assign_var(tensor, value, child_context)
        when :add
          execute_2_operand_func('add', tensor, a, b, child_context)
        when :div
          execute_2_operand_func('div', tensor, a, b, child_context)
        when :sub
          execute_2_operand_func('sub', tensor, a, b, child_context)
        when :matmul
          a = _run(a, child_context)
          b = _run(b, child_context)

          m = a.shape[0]
          n = b.shape[1]
          v = b.shape[0]
          k = a.shape[1]

          m, k = [a.shape[1], a.shape[0]] if tensor.options[:transpose_a]
          n, v = [b.shape[0], b.shape[1]] if tensor.options[:transpose_b]

          result_shape = [m, n]

          raise "#{tensor.items[0].name} rank must be greater than 1" if a.shape.size < 2
          raise "#{tensor.items[1].name} rank must be greater than 1" if b.shape.size < 2
          raise "incompatible shape sizes for matrix multiplication (#{a.shape[1]} != #{b.shape[0]}) #{a.shape} vs #{b.shape}" if k != v

          dtype = TensorStream::Ops::FLOATING_POINT_TYPES.include?(tensor.data_type) ? 'fp' : 'int'
          a, b = type_cast(a, b)
          output_buffer = _create_result_buffer(a.data_type, result_shape, tensor.name)

          cl_m = OpenCL::Int1.new(m)
          cl_n = OpenCL::Int1.new(n)
          cl_k = OpenCL::Int1.new(k)

          transpose_a = OpenCL::Int1.new(tensor.options[:transpose_a] ? 1 : 0)
          transpose_b = OpenCL::Int1.new(tensor.options[:transpose_b] ? 1 : 0)

          output_buffer.op = _cl_program('gemm').send(:"gemm_#{dtype}", _opencl_queue, result_shape, cl_m, cl_n, cl_k, transpose_a, transpose_b, a.cl_buffer, b.cl_buffer, output_buffer.cl_buffer)
          output_buffer
        when :mul
          execute_2_operand_func('mul', tensor, a, b, child_context)
        when :pow
          execute_2_operand_func('pow', tensor, a, b, child_context)
        when :sign
          execute_func('sign', tensor, a, child_context)
        when :exp
          execute_func('exp', tensor, a, child_context)
        when :log
          execute_func('log', tensor, a, child_context)
        when :sin
          execute_func('sin', tensor, a, child_context)
        when :tan
          execute_func('tan', tensor, a, child_context)
        when :cos
          execute_func('cos', tensor, a, child_context)
        when :abs
          execute_func('abs', tensor, a, child_context)
        when :sqrt
          execute_func('sqrt', tensor, a, child_context)
        when :negate
          execute_func('negate', tensor, a, child_context)
        when :square
          execute_func('square', tensor, a, child_context)
        when :reciprocal
          execute_func('reciprocal', tensor, a, child_context)
        when :tanh
          execute_func('tanh', tensor, a, child_context)
        when :tanh_grad
          execute_func('tanh_grad', tensor, a, child_context)
        when :sigmoid
          execute_func('sigmoid', tensor, a, child_context)
        when :sigmoid_grad
          execute_2_operand_func('sigmoid_grad', tensor, a, b, child_context)
        when :truncate
          a = _run(a, child_context)
          b = _run(b, child_context)

          if a.shape.size.zero?
            a
          else
            input_b = read_final_result(b)
            if a.shape == input_b
              a
            else
              input_a = read_final_result(a)
              wrap_opencl(i_cons(truncate(input_a, input_b), data_type: a.data_type), name: "#{tensor.name}")
            end
          end
        when :zeros, :ones, :zeros_like, :ones_like
          shape = if %i[zeros_like ones_like].include?(tensor.operation)
            _run(a, child_context).shape
          else
            read_final_result(complete_eval(a, child_context)) || tensor.shape.shape
          end

          func = if %i[zeros zeros_like].include?(tensor.operation)
            -> { tensor.data_type == :int32 ? 0 : 0.0 }
          else
            -> { tensor.data_type == :int32 ? 1 : 1.0 }
          end

          size = shape.empty? ? 1 : shape.reduce(:*)

          buffer = if TensorStream::Ops::FLOATING_POINT_TYPES.include?(tensor.data_type)
                      NArray.sfloat(size)
                    elsif TensorStream::Ops::INTEGER_TYPES.include?(tensor.data_type)
                      NArray.int(size)
                    else
                      raise "unsupported type #{tensor.data_type}"
                    end

          data = if !shape.empty?
            Array.new(size) do |index|
              func.call
            end
          else
            func.call
          end

          convert_to_opencl(data, shape, data_type: tensor.data_type, name: tensor.name)
         when :broadcast_transform
          a = _run(a, child_context)
          b = _run(b, child_context)

         if a.shape == b.shape
           [a, b]
         else
           input_a = read_final_result(complete_eval(a, child_context))
           input_b = read_final_result(complete_eval(b, child_context))
           b_a, b_b = broadcast(input_a, input_b)
           [ wrap_opencl(i_cons(b_a, data_type: a.data_type), name: "#{tensor.name}_a"),
             wrap_opencl(i_cons(b_b, data_type: b.data_type), name: "#{tensor.name}_b")]
         end
        when :index
          a = complete_eval(a, child_context)
          input_a = read_final_result(a)
          index = read_final_result(complete_eval(b, child_context))
          if a.is_a?(Array)
            a[index]
          else
            new_shape = a.shape.dup
            new_shape.shift
            convert_to_opencl(input_a[index], new_shape, data_type: a.data_type, name: tensor.name)
          end
        when :broadcast_gradient_args
          a = complete_eval(a, child_context)
          b = complete_eval(b, child_context)

          wrap_opencl(i_cons(get_broadcast_gradient_args(a.buffer.to_a, b.buffer.to_a), data_type: :int32), name: tensor.name)
        when :shape
          a = _run(a, child_context)

          wrap_opencl(i_cons(a.shape), name: tensor.name, data_type: tensor.options[:out_type] || :float32)
        when :reshape
          arr = complete_eval(a, child_context)
          new_shape = read_final_result(complete_eval(b, child_context))

          if new_shape.size.zero? && arr.buffer.size == 1
            arr.shape = new_shape
            arr
          else
            new_shape = TensorShape.fix_inferred_elements(new_shape, arr.buffer.size)
            arr.shape = new_shape
            arr
          end
        when :random_uniform
          maxval = tensor.options.fetch(:maxval, 1)
          minval = tensor.options.fetch(:minval, 0)
          seed = tensor.options[:seed]

          random = _get_randomizer(tensor, seed)
          generator = -> { random.rand * (maxval - minval) + minval }
          shape = tensor.options[:shape] || tensor.shape.shape
          
          convert_to_opencl(generate_vector(shape, generator: generator), shape, data_type: tensor.data_type, name: tensor.name)
        when :random_normal
          random = _get_randomizer(tensor, seed)
          r = RandomGaussian.new(tensor.options.fetch(:mean), tensor.options.fetch(:stddev), -> { random.rand })
          random = _get_randomizer(tensor, seed)
          generator = -> { r.rand }
          shape = tensor.options[:shape] || tensor.shape.shape

          convert_to_opencl(generate_vector(shape, generator: generator), shape, data_type: tensor.data_type, name: tensor.name)
        when :glorot_uniform
          random = _get_randomizer(tensor, seed)

          shape = tensor.options[:shape] || tensor.shape.shape
          fan_in, fan_out = if shape.size.zero?
                              [1, 1]
                            elsif shape.size == 1
                              [1, shape[0]]
                            else
                              [shape[0], shape.last]
                            end

          limit = Math.sqrt(6.0 / (fan_in + fan_out))

          minval = -limit
          maxval = limit

          generator = -> { random.rand * (maxval - minval) + minval }
          convert_to_opencl(generate_vector(shape, generator: generator), shape, data_type: tensor.data_type, name: tensor.name)
        when :flow_group
          tensor.items.collect { |item| _run(item, child_context) }
        when :sum
          reduction(child_context, tensor, a, b, :sum)
        when :prod
          reduction(child_context, tensor, a, b, :prod)
        when :argmin
          a = complete_eval(a, child_context)
          axis = tensor.options[:axis] || 0
          arr = a.buffer.reshape(*a.shape.reverse).to_a
          op = get_op_with_axis(arr, axis, 0, a.data_type, ->(a, b) { a < b })
          convert_to_opencl(op, shape_eval(op), data_type: tensor.data_type, name: tensor.name)
        when :argmax
          a = complete_eval(a, child_context)
          axis = tensor.options[:axis] || 0
          arr = a.buffer.reshape(*a.shape.reverse).to_a
          op = get_op_with_axis(arr, axis, 0, a.data_type, ->(a, b) { a > b })
          convert_to_opencl(op, shape_eval(op), data_type: tensor.data_type, name: tensor.name)
        else
          raise "unknown op #{tensor.operation}"
        end.tap do |result|
          if tensor.breakpoint
            a = read_final_result(complete_eval(a, child_context))
            b = read_final_result(complete_eval(b, child_context))
            result = read_final_result(complete_eval(result, child_context))

            tensor.breakpoint.call(tensor, a, b, result)
          end
          if @log_intermediates
            @context[:compute_history] << {
              name: tensor.name,
              type: tensor.data_type,
              shape: shape_eval(result),
              source: tensor.source,
              description: tensor.to_math(true, 1),
              value: result
            }
          end
          @context[tensor.name] = result
        end
      rescue EvaluatorExcecutionException => e
        raise e
      rescue StandardError => e
        puts e.message
        puts e.backtrace.join("\n")
        # binding.pry
        # shape_a = a.shape.shape if a
        # shape_b = b.shape.shape if b
        # dtype_a = a.data_type if a
        # dtype_b = b.data_type if b
        # a = complete_eval(a, child_context)
        # b = complete_eval(b, child_context)
        # puts "name: #{tensor.given_name}"
        # # puts "op: #{tensor.to_math(true, 1)}"
        # puts "A #{shape_a} #{dtype_a}: #{a}" if a
        # puts "B #{shape_b} #{dtype_b}: #{b}" if b
        # dump_intermediates if @log_intermediates
        # File.write('/home/jedld/workspace/tensor_stream/samples/error.graphml', TensorStream::Graphml.new.get_string(tensor, @session))

        # File.write('/Users/josephemmanueldayo/workspace/gradients.graphml', TensorStream::Graphml.new.get_string(tensor, @session))
        raise EvaluatorExcecutionException.new(e, tensor), "error #{e.message} while evaluating #{tensor.name} : #{tensor.to_math(true,1)} defined at #{tensor.source}"
      end

      def eval_tensor(tensor, child_context)
        return tensor unless tensor.is_a?(Tensor)
        return @context[tensor.name] if @context.key?(tensor.name)
        return @context[:_cache][tensor.name] if tensor.is_const && @context[:_cache][tensor.name]
        @context[tensor.name] = tensor.value.is_a?(Tensor) ? _run(tensor.value, child_context) : @context[:_cache][tensor.name] = wrap_opencl(tensor, name: tensor.name)
      end

      private

      def assign_var(tensor, b, child_context)
        assign = tensor.items[0] || tensor
        buffer = complete_eval(b, child_context)
        # assign.value = read_final_result(buffer)
        if assign.buffer
          assign.buffer.op = _opencl_queue.enqueue_write_buffer(assign.buffer.cl_buffer, buffer.buffer)
        else
          assign.buffer = convert_to_opencl(read_final_result(buffer), buffer.shape, data_type: tensor.data_type, name: tensor.name)
        end
        assign.buffer.dirty = true
        assign.buffer
      end
    
      def execute_2_operand_func(op_name, tensor, input_a, input_b, child_context)
        a = _run(input_a, child_context)
        b = _run(input_b, child_context)
        a, b = type_cast(a, b)
        dtype = TensorStream::Ops::FLOATING_POINT_TYPES.include?(tensor.data_type) ? 'fp' : 'int'

        result_shape = TensorShape.infer_shape(a.shape, b.shape)
        output_buffer = _create_result_buffer(tensor.data_type, result_shape, tensor.name)
        a, b, prog, switch_operands = select_program(a, b, op_name)
        m, n = result_shape
        work_group = [m || 1, n || 1]
        cl_m = OpenCL::Int1.new(m || 1)
        cl_n = OpenCL::Int1.new(n || 1)
        cl_switch = OpenCL::Int1.new(switch_operands) # no need to switch for addition
        
        event_wait_list = [a.op, b.op].compact # add dependency wait list

        event = if prog == "#{op_name}_b"
          cl_m_b, cl_n_b = if b.shape.size == 2
            [ OpenCL::Int1.new(b.shape[0]), OpenCL::Int1.new(b.shape[1]) ]
          elsif b.shape.size == 1
            [ OpenCL::Int1.new(1), OpenCL::Int1.new(b.shape[0]) ]
          else
            raise "rank > 2 not supported!"
          end
          _cl_program("#{op_name}").send(:"#{prog}_#{dtype}", _opencl_queue, work_group, cl_m, cl_n, cl_m_b, cl_n_b, cl_switch, a.cl_buffer, b.cl_buffer, output_buffer.cl_buffer, event_wait_list: event_wait_list)
        else
          _cl_program("#{op_name}").send(:"#{prog}_#{dtype}", _opencl_queue, work_group, cl_m, cl_n, cl_switch, a.cl_buffer, b.cl_buffer, output_buffer.cl_buffer, event_wait_list: event_wait_list)
        end
        output_buffer.op = event
        output_buffer
      end

      def execute_func(op_name, tensor, a, child_context)
        a = _run(a, child_context)
        event_wait_list = [a.op].compact 
        dtype = TensorStream::Ops::FLOATING_POINT_TYPES.include?(tensor.data_type) ? 'fp' : 'int'
        output_buffer = _create_result_buffer(tensor.data_type, a.shape, tensor.name)

        m, n = a.shape
        work_group = [m || 1, n || 1]
        cl_m = OpenCL::Int1.new(m || 1)
        cl_n = OpenCL::Int1.new(n || 1)

        event = _cl_program("#{op_name}").send(:"#{op_name}_#{dtype}", _opencl_queue, work_group, cl_m, cl_n, a.cl_buffer, output_buffer.cl_buffer, event_wait_list: event_wait_list)
        output_buffer.op = event
        output_buffer
      end

      def type_cast(a, b)
        return [a, b] if a.data_type == b.data_type
        m, n = b.shape
        work_group = [m || 1, n || 1]
        buffer = buffer_for(b.shape, b.data_type)
        if (TensorStream::Ops::FLOATING_POINT_TYPES.include?(a.data_type.to_sym))
          if TensorStream::Ops::INTEGER_TYPES.include?(b.data_type.to_sym)
            cl_m = OpenCL::Int1.new(m || 1)
            cl_n = OpenCL::Int1.new(n || 1)

            _cl_program("cast").cast_int_fp(_opencl_queue, work_group, cl_m, cl_n, b.cl_buffer, buffer.cl_buffer)
            return [a, buffer]
          end
        elsif TensorStream::Ops::INTEGER_TYPES.include?(a.data_type.to_sym)
          if TensorStream::Ops::FLOATING_POINT_TYPES.include?(b.data_type.to_sym)
            cl_m = OpenCL::Int1.new(m || 1)
            cl_n = OpenCL::Int1.new(n || 1)
            _cl_program("cast").cast_fp_int(_opencl_queue, work_group, cl_m, cl_n, b.cl_buffer, buffer.cl_buffer)
            return [a, buffer]
          end
        end

        [a, b]
      end

      def buffer_for(shape, data_type)
        size = shape.empty? ? 1 : shape.reduce(:*)

        buffer = if TensorStream::Ops::FLOATING_POINT_TYPES.include?(data_type.to_sym)
          NArray.sfloat(size)
        elsif TensorStream::Ops::INTEGER_TYPES.include?(data_type.to_sym)
          NArray.int(size)
        elsif data_type.to_sym == :boolean
          NArray.sint(size)
        else
          raise "unsupported type #{data_type}"
        end
        cl_buffer = _opencl_context.create_buffer(buffer.size * buffer.element_size)
        OpenCLBuffer.new(data_type: data_type, shape: shape, buffer: buffer, cl_buffer: cl_buffer)
      end

      def wrap_opencl(tensor, data_type: nil, name: nil)
        convert_to_opencl(tensor.value, tensor.shape.shape, data_type: data_type || tensor.data_type, name: name)
      end

      def convert_to_opencl(value, shape, data_type: nil, name: nil)
        cache_key = "_cl_object_#{name}_#{shape.join('_')}"
        cl_object =  if name && @context[:_cache][cache_key]
                      @context[:_cache][cache_key]
                     else
                       size = shape.empty? ? 1 : shape.reduce(:*)
                       buffer = if value.is_a?(NArray)
                          value
                       elsif TensorStream::Ops::FLOATING_POINT_TYPES.include?(data_type.to_sym) || TensorStream::Ops::FLOATING_POINT_TYPES.include?(data_type.to_sym)
                         NArray.sfloat(size)
                       elsif TensorStream::Ops::INTEGER_TYPES.include?(data_type.to_sym) || TensorStream::Ops::INTEGER_TYPES.include?(data_type.to_sym)
                         NArray.int(size)
                       elsif data_type.to_sym == :boolean
                         NArray.sint(size)
                       else
                         raise "unsupported type #{data_type}"
                       end

                       cl_buffer = if size > 0
                        _opencl_context.create_buffer(buffer.size * buffer.element_size)
                       else
                        nil
                       end

                       @context[:_cache][cache_key] = OpenCLBuffer.new(name: name, data_type: data_type, shape: shape, buffer: buffer, cl_buffer: cl_buffer)
                     end

        if value.is_a?(Array)
          value.flatten.each_with_index do |element, index|
            if element.is_a?(Tensor)
              cl_object.buffer[index] = read_final_result(complete_eval(element, {}))
            else
              cl_object.buffer[index] = Tensor.cast_dtype(element, data_type)
            end
          end
        elsif value.is_a?(NArray)
          cl_object.buffer = value
        else
          cl_object.buffer[0] = Tensor.cast_dtype(value, data_type)
        end

        write_op = if !value.nil? && (!value.is_a?(Array) || !value.empty?)
          _opencl_queue.enqueue_write_buffer(cl_object.cl_buffer, cl_object.buffer)
        end
        cl_object.op = write_op
        cl_object
      end


      def _create_result_buffer(data_type, shape, name)
        @context[:_cache]["_result_#{name}_#{shape.join('_')}"] ||= begin
          size = shape.empty? ? 1 : shape.reduce(:*)
          buffer =  if TensorStream::Ops::FLOATING_POINT_TYPES.include?(data_type)
                      NArray.sfloat(size)
                    elsif TensorStream::Ops::INTEGER_TYPES.include?(data_type)
                      NArray.int(size)
                    else
                      raise "unsupported type #{data_type}"
                    end
          cl_buffer = _opencl_context.create_buffer(buffer.size * buffer.element_size)
          OpenCLBuffer.new(data_type: data_type, shape: shape, buffer: buffer, cl_buffer: cl_buffer)
        end
      end

      def get_op_with_axis(a, target_axis, current_axis, output_type, op = ->(t, u) { t > u })
        if target_axis == current_axis
          if a[0].is_a?(Array)
            (0...a[0].size).each.collect do |column_index|
              max = nil
              max_index = 0
              a.each_with_index do |row, row_index|
                if max.nil? || op.call(row[column_index], max)
                  max = row[column_index]
                  max_index = row_index
                end
              end

              Tensor.cast_dtype(max_index, output_type)
            end
          else
            max = nil
            max_index = 0
            a.each_with_index do |x, index|
              if max.nil? || op.call(x, max)
                max = x
                max_index = index
              end
            end
            Tensor.cast_dtype(max_index, output_type)
          end
        else
          a.collect do |row|
            get_op_with_axis(row, target_axis, current_axis + 1, output_type, op)
          end
        end
      end

      def reduction(child_context, tensor, a, b, func)
        input = complete_eval(a, child_context)
        axis = read_final_result(complete_eval(b, child_context))
        if axis.nil?
          convert_to_opencl(input.buffer.send(func), [], data_type: tensor.data_type, name: tensor.name)
        else
          value = input.buffer.reshape(*input.shape.reverse)
          rank = input.shape.size - 1

          if axis.is_a?(Array)
            axis.map{ |x| rank - x.abs }.sort.reverse.each do |x|
              value = value.send(func, x)
            end
          else
            value = value.send(func, rank - axis.abs)
          end

          new_shape = if value.is_a?(NArray)
            value.shape.reverse
          else
            value = [value]
            []
          end

          if tensor.options[:keepdims]
            new_shape = reduced_shape(input.shape.dup, axis)
          end

          convert_to_opencl(value.flatten, new_shape, data_type: tensor.data_type, name: tensor.name)
        end
      end

      def arr_pad(arr, paddings, data_type = :float32, rank = 0)
        raise "padding #{paddings[rank]} needs to have to elements [before, after]" if paddings[rank].size != 2

        before = paddings[rank][0]
        after = paddings[rank][1]
        pad_value = fp_type?(data_type) ? 0.0 : 0
        if arr[0].is_a?(Array)
          next_dim_elem = arr.collect { |a| arr_pad(a, paddings, data_type, rank + 1) }
          padding = deep_dup_array(next_dim_elem[0], pad_value)
          Array.new(before) { padding } + next_dim_elem + Array.new(after) { padding }
        else
          Array.new(before) { pad_value } + arr + Array.new(after) { pad_value }
        end
      end

      def deep_dup_array(arr, value = nil)
        if arr.is_a?(Array)
          arr.dup.collect do |a|
            deep_dup_array(a, value)
          end
        else
          value.nil? ? arr : value
        end
      end

      def matmul_const_transform(mat, mat_b, tensor)
        if !mat.is_a?(Array)
          compat_shape = shape_eval(mat_b).reverse
          func = -> { tensor.data_type == :int32 ? mat.to_i : mat.to_f }

          generate_vector(compat_shape, generator: func)
        else
          mat
        end
      end

      def call_op(op, a, child_context, func)
        a = complete_eval(a, child_context)
        process_function_op(a, child_context, func)
      rescue FullEvalNotPossible
        TensorStream.send(op.to_sym, a)
      end

      def call_vector_op(op, a, b, child_context, func)
        process_vector_math_op(a, b, child_context, func)
      rescue FullEvalNotPossible
        TensorStream.send(op.to_sym, a, b)
      end

      def process_vector_math_op(a, b,  child_context, op)
        eval_a = complete_eval(a, child_context) unless a.nil?
        eval_b = complete_eval(b, child_context) unless b.nil?

        raise FullEvalNotPossible.new, "full eval not possible for #{a.name}" if eval_a.is_a?(Tensor) || eval_b.is_a?(Tensor)

        # ruby scalar
        eval_a, eval_b = broadcast(eval_a, eval_b)
        vector_op(eval_a, eval_b, op)
        # if get_rank(eval_a).zero?
        #   if get_rank(eval_b).zero?
        #     op.call(eval_a, eval_b)
        #   else
        #     vector_op(eval_b, eval_a, op, true)
        #   end
        # else
        #   vector_op(eval_a, eval_b, op)
        # end
      end

      # determine possible reduction axis to be used
      def _broadcast_gradient_op(vector_shape1, vector_shape2, level)
        va_rank = _rank_from_shape(vector_shape1)
        vb_rank = _rank_from_shape(vector_shape2)
        return [] if vector_shape1 == vector_shape2 # same shape so no reductions

        shape2_r = vector_shape2.reverse

        vector_shape1.reverse.each_with_index.collect do |s, index|
          next va_rank - index - 1 if index >= shape2_r.size
          next nil if shape2_r[index] == s
          next nil if shape2_r[index] > s
          va_rank - index - 1
        end.compact
      end

      # selects variants of cl programs depending on input
      def select_program(input_a, input_b, op)
        return [input_a, input_b, "#{op}", 0] if input_a.shape == input_b.shape

        return [input_b, input_a, "#{op}_c", 1] if input_a.shape.empty? || input_a.shape.reduce(:*) == 1 # A is scalar?
        return [input_a, input_b, "#{op}_c", 0] if input_b.shape.empty? || input_a.shape.reduce(:*) == 1 # B is scalar?

        return [input_b, input_a, "#{op}_b", 1] if input_a.shape.size < input_b.shape.size

        if input_a.shape.size == input_b.shape.size
          input_a.shape.zip(input_b.shape).each do |s1, s2|
            return [input_b, input_a, "#{op}_b", 1] if s1 < s2
          end
        end

        [input_a, input_b, "#{op}_b", 0]
      end

      def _rank_from_shape(shape)
        shape.is_a?(Array) ? shape.size : 0
      end

      def get_broadcast_gradient_args(input_a, input_b)
        return [] if get_rank(input_b).zero? && get_rank(input_a).zero?
        return nil if get_rank(input_b).zero?
        # ruby scalar
        if get_rank(input_a).zero?
          _broadcast_gradient_op(input_b, input_a, 0, true)
        elsif get_rank(input_a) > 0
          _broadcast_gradient_op(input_a, input_b, 0)
        end
      end

      def get_rank(value, rank = 0)
        return rank unless value.is_a?(Array)
        return rank + 1 if value.empty?

        get_rank(value[0], rank + 1)
      end

      def concat_array(values, axis)
        combined_array = values.shift
        axis = get_rank(combined_array) - 1 if axis == -1

        values.each do |v|
          combined_array = concat(combined_array, v, axis)
        end
        combined_array
      end

      def concat(a, b, axis)
        if axis.zero?
          a + b
        else
          a.each_with_index.collect do |i, index|
            concat(i, b[index], axis - 1)
          end
        end
      end

      def process_function_op(a, child_context, op)
        # ruby scalar
        if (a.is_a?(Tensor) && a.shape.rank > 0) || a.is_a?(Array)
          vector_op(a, 0, op)
        elsif !a.is_a?(Tensor) || a.shape.rank.zero?
          v = _run(a, child_context)
          raise FullEvalNotPossible.new, "full eval not possible for #{v.name}" if v.is_a?(Tensor) && !v.is_const

          op.call(v, 0)
        else
          raise 'cannot be here'
        end
      end

      def resolve_placeholder(placeholder, _execution_context = {})
        return nil if placeholder.nil?
        return placeholder if retain.include?(placeholder)

        var = if placeholder.is_a?(Placeholder)
                @context[placeholder.name.to_sym].tap do |c|
                  raise "missing placeholder #{placeholder.name}" if c.nil?
                end
              else
                placeholder
              end

        return convert_to_opencl(var, shape_eval(var), data_type: placeholder.data_type, name: placeholder.name) unless var.is_a?(Tensor)
        Tensor.cast_dtype(var, placeholder.data_type)
      end

      def reduce_axis(current_axis, axis, val, keep_dims, f = ->(a, b) { a + b })
        return val unless val.is_a?(Array)

        r = val.collect do |v|
          reduce_axis(current_axis + 1, axis, v, keep_dims, f)
        end

        should_reduce_axis = axis.nil? || (axis.is_a?(Array) && axis.include?(current_axis)) || (current_axis == axis)

        if should_reduce_axis
          reduced_val = r[0]
          if r.size > 1
            reduced_val = f.call(r[0..val.size])
          elsif r.size == 0
            reduced_val = f.call(nil)
          end
          keep_dims ? [ reduced_val ] : reduced_val
        else
          r
        end
      end

      # handle 3 tensor math operations
      def call_3way_vector_op(v_a, v_b, v_c, child_context, op = ->(a, b, c) { a + b + c })
        return op.call(v_a, v_b, v_c) unless v_a.is_a?(Array)

        v_a.each_with_index.collect do |v1, index|
          v2 = v_b[index]
          v3 = v_c[index]
          if v1.is_a?(Array)
            call_3way_vector_op(v1, v2, v3, child_context, op)
          else
            op.call(v1, v2, v3)
          end
        end
      end

      def all_true?(arr)
        if arr.is_a?(Array)
          arr.each do |a|
            return false unless all_true?(a)
          end
          return true
        end

        !!arr
      end

      def generate_vector(shape, dtype: :float32, generator:)
        if shape.is_a?(Integer)
          Array.new(shape) do
            generator.call
          end
        elsif shape.size > 1
          Array.new(shape[0]) do
            generate_vector(shape[1..shape.size], generator: generator, dtype: dtype)
          end
        elsif shape.size == 1
          Array.new(shape[0]) do
            generator.call
          end
        elsif shape.size.zero?
          generator.call
        end
      end

      def _get_randomizer(tensor, seed)
        if tensor.graph.random_seed && seed
          Random.new(tensor.graph.random_seed ^ seed)
        elsif tensor.graph.random_seed
          @session.randomizer[tensor.graph.object_id] ||= Random.new(tensor.graph.random_seed)
          @session.randomizer[tensor.graph.object_id]
        elsif seed
          @session.randomizer[tensor.operation] ||= Random.new(seed)
          @session.randomizer[tensor.operation]
        else
          Random.new
        end
      end

      def dump_intermediates
        arr = []
        arr << "============== start ==================="
        @context[:compute_history].each_with_index do |history, index|
          arr << "------------------------------------"
          arr << history[:name]
          arr << "#{history[:type]} #{history[:shape]}"
          arr << history[:source]
          arr << history[:description]
          arr << ""
          arr << history[:value].to_json
          arr << "------------------------------------"
        end
        arr << "============== end ====================="
        str = arr.join("\n")
        File.write("/tmp/intermediates.txt", str)
      end
    end
  end
end
