# frozen_string_literal: true

module Freentonic
  module ExtractPlan
    # Evaluates a `when: { binding: { op: operand } }` gate against a Scope,
    # reusing the workflow's `when_context` operator set (gt/gte/lt/lte,
    # eq/neq, present/absent). Shared by two loci so their semantics can
    # never drift: the plan interpreter's per-step gate and the elevate
    # phase's block-level gate. Operator/operand shapes are validated
    # statically at load (WorkflowSchema#validate_plan_when!); this is the
    # runtime side.
    module WhenGate
      module_function

      # True when every declared key/op holds. An empty/nil gate passes.
      def passes?(gate, scope)
        return true if gate.nil? || gate.empty?
        gate.all? do |key, ops|
          actual = scope.get(key)
          ops.all? { |op, operand| compare(actual, op, operand, key) }
        end
      end

      def compare(actual, op, operand, key)
        case op
        when "gt"      then numeric!(actual, key) >  operand
        when "gte"     then numeric!(actual, key) >= operand
        when "lt"      then numeric!(actual, key) <  operand
        when "lte"     then numeric!(actual, key) <= operand
        when "eq"      then actual == operand
        when "neq"     then actual != operand
        when "present" then operand == true ? !actual.nil? : actual.nil?
        when "absent"  then operand == true ? actual.nil? : !actual.nil?
        else raise UserError, "when: unknown operator #{op.inspect} on key #{key.inspect}"
        end
      end

      def numeric!(val, key)
        return val if val.is_a?(Numeric)
        raise UserError, "when: key #{key.inspect} requires a numeric value, got #{val.inspect}"
      end
    end
  end
end
