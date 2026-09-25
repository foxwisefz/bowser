# Hermetic-test guards live in config/config.exs (loaded BEFORE app boot —
# put_env here has a boot-window gap that once let tests reach the real
# engine). See test/hermetic_test.exs for the enforcement.
ExUnit.start(exclude: if(System.get_env("BOWSER_LIVE_AUDIT_TEST") == "1", do: [], else: [:live_audit]))
