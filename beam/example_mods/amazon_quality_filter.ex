# Opt-in example: sends visible Amazon.com listing text to Bowser/TypeSafe.
# Uses content quality, not price or an assumption about AI authorship.
defmodule AmazonQualityFilter do
  use BowserBrain.Mod, host: "amazon.com"
  def init_mod(_), do: BowserBrain.QualityFilter.init("amazon")
  def handle_event(event, state), do: BowserBrain.QualityFilter.event(event, state)

  def handle_info({:quality_result, _, _, _} = result, state),
    do: {:noreply, BowserBrain.QualityFilter.result(result, state)}

  def handle_info(message, state), do: super(message, state)
end
