module Resque
  module Plugins
    module Telework
      Name = NAME = 'resque-telework'
      Nickname = NICKNAME = 'telework'
      Version = VERSION = '0.3.3'
      RedisInterfaceVersion = REDIS_INTERFACE_VERSION = '2'
      StatsResolution = STATS_RESOLUTION = 60
      QueueTags = QUEUE_TAGS = %w{critical downscalable}
    end
  end
end
