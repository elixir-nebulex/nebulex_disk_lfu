# Mocks
[File]
|> Enum.each(&Mimic.copy/1)

# Start Telemetry
_ = Application.start(:telemetry)

# Disable testing expired event on observable tests
:ok = Application.put_env(:nebulex, :observable_test_expired, false)

# Start ExUnit
ExUnit.start()
