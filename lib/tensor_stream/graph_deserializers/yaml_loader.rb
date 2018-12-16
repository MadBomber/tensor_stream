module TensorStream
  class YamlLoader
    def initialize(graph = nil)
      @graph = graph || TensorStream.get_default_graph
    end

    def load_from_string(buffer)
      serialized_ops = YAML.safe_load(buffer, [Symbol])
      serialized_ops.each do |op_def|
        inputs = op_def[:inputs].map { |i| @graph.get_tensor_by_name(i) }
        options = {}

        if op_def.dig(:attrs, :container)
          new_var = Variable.new(op_def.dig(:attrs, :data_type))
          var_shape = op_def.dig(:attrs, :container, :shape)
          var_options = op_def.dig(:attrs, :container, :options)
          var_options[:name] = op_def[:name]

          new_var.prepare(var_shape.size, var_shape, TensorStream.get_variable_scope, var_options)
          options[:container] = new_var

          @graph.add_variable(new_var, var_options)
        end

        new_op = Operation.new(@graph, inputs: inputs, options: op_def[:attrs].merge(options))
        new_op.operation = op_def[:op].to_sym
        new_op.name = op_def[:name]
        new_op.shape = TensorShape.new(TensorStream::InferShape.infer_shape(new_op))
        new_op.rank = new_op.shape.rank
        new_op.data_type = new_op.set_data_type(op_def.dig(:attrs, :data_type))
        new_op.is_const = new_op.infer_const
        new_op.given_name = new_op.name

        @graph.add_node(new_op)
      end
    end
  end
end