import Config

# Prevent the Poller from starting in test env; it would make real network calls.
config :umarell, :start_poller, false
