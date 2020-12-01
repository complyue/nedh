# Distributed Concurrency / Parallelism

> Do perform **Remote Procedure Calls**, but try avoid **Remote Objects** (thus **Remote References**) like the plague - remote garbage collection, remote reference counting, or manual release of remote objects? That's seriously unhealthy, and there will be no cure.

**RPC** is a primitive mechanism for distributed communication. But remote objects is not so, and apparently harmful, all objects should be managed locally.

**Message Channels** can be used to eliminate the needs for remote objects in many cases. The peer site can react to messages posted through specific channels and manage local states accordingly. After the peer lost interests with a channel, it can just discard that channel and release local resources associated with it. It's ideal to notify the peer to not send messages to that channel anymore, while a peer can choose to allow subsequent messages for resilience purpose, maybe with some warning logged, but fail not.
