# Opt-in example: sends visible X post text to Bowser/TypeSafe for quality judgments.
# It cannot establish AI authorship. Hidden content always has a Show control.
defmodule XQualityFilter do
  use BowserBrain.Mod, host: "x.com"
  def init_mod(_), do: BowserBrain.QualityFilter.init("x")
  def handle_event(event, state), do: BowserBrain.QualityFilter.event(event, state)

  def handle_info({:quality_result, _, _, _} = result, state),
    do: {:noreply, BowserBrain.QualityFilter.result(result, state)}

  def handle_info(message, state), do: super(message, state)
end
