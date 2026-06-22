import Config

config :umarell, :start_poller, true

import_config "#{config_env()}.exs"
