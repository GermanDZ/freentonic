# frozen_string_literal: true

module Freentonic
  # The `when_context` operator set — the single source of truth for the
  # comparison operators accepted by the two loci that gate steps on
  # runtime values:
  #
  #   * the browser workflow runner's step-level `when_context:` gate
  #     (BrowserWorkflowRunner#compare_context), and
  #   * the extract/normalize/elevate plan `when:` gate
  #     (ExtractPlan::WhenGate#compare).
  #
  # Both keep an explicit `case` dispatch (their numeric-coercion semantics
  # differ — the runner coerces both operands via `numeric!`, the plan gate
  # compares against a raw operand); this constant lists the operator names
  # so they can never drift, and so SchemaExport can emit them as data. A
  # drift-guard test asserts each `case` arm equals this list.
  module WhenContext
    OPERATORS = %w[gt gte lt lte eq neq present absent].freeze
  end
end
