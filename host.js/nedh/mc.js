/**
 * A Nedh MessageChannel connection is established through a pair of
 * `MessagePort` (must from 2 separate `MessageChannel`) as transport
 */

import { EventSink } from "edh"

/**
 * Nedh Peer Interface over a pair of `MessagePort` (must from 2 separate
 * `MessageChannel`).
 */
export class McPeer {
  constructor(portIn, portOut, lander) {
    this.in = portIn
    this.out = portOut
    this.lander = lander
    this._closeNotifs = []
    this.eol = new Promise((resolve, reject) => {
      this._closeNotifs.push([resolve, reject])
    })
    this.disposals = new Set()
    this.channels = {}
    this.eol.finally(() => this.cleanup())

    this.in.onmessage = async (me) => {
      // cmd to default channel
      if ("string" === typeof me.data) {
        const cmdVal = await lander.land(me.data, null)
        // to the default channel, only side-effects desirable
        if (undefined !== cmdVal) {
          // console.warn(
          //   "Some " +
          //     typeof cmdVal +
          //     " value resulted in the default channel: ",
          //   cmdVal,
          //   me.data
          // )
        }
        return
      }

      // cmd to some identified channel
      const { dir, blob, src } = me.data
      if (undefined === dir) {
        throw Error("bug: obj pkt without dir")
      }
      // todo implement the same level of indirections as Nedh for dir?
      //      i.e. eval dir to get chLctr
      const chLctr = dir
      const ch = this.channels[chLctr]

      // case of a blob packet
      if (undefined !== blob) {
        if (ch instanceof EventSink) {
          ch.publish(blob)
        } else {
          console.error(
            "Nedh usage error: bad channel locator for a blob packet",
            chLctr
          )
        }
        return
      }

      // case of a command packet
      if ("string" === typeof src) {
        const cmdVal = await lander.land(src, chLctr)
        // publish to sink of specified channel
        const ch = this.channels[chLctr]
        if (ch instanceof EventSink) {
          ch.publish(cmdVal)
        } else {
          console.error("Nedh usage error: bad channel locator", chLctr)
        }
      }

      // unexpected payload schema
      console.error("msg with invalid payload:", me)
      debugger
      throw Error("invalid payload data: " + me.data)
    }
  }

  cleanup() {
    // mark all channels end-of-stream on peer end-of-life
    for (const ch of this.disposals) {
      ch.publish(null)
    }
  }

  async handleError(err, errDetails) {
    console.error(err, errDetails)
  }

  stop() {
    this.lander.terminate() // terminate the lander anyway when closed

    for (const [resolve, _reject] of this._closeNotifs) {
      resolve(true)
    }
  }

  armedChannel(chLctr) {
    return this.channels[chLctr]
  }

  ensureChannel(chLctr, dispose = true) {
    let ch = this.channels[chLctr]
    if (undefined === ch) {
      ch = this.channels[chLctr] = new EventSink()
      if (dispose) {
        this.disposals.add(ch)
      }
    }
    return ch
  }

  armChannel(chLctr, chSink, dispose = true) {
    if (undefined === chSink) {
      chSink = new EventSink()
    } else if (!(chSink instanceof EventSink)) {
      throw Error("not an event sink: " + chSink)
    }
    this.channels[chLctr] = chSink
    if (dispose) {
      this.disposals.add(chSink)
    }
    return chSink
  }

  dispose(sink) {
    this.disposals.add(sink)
  }

  postCommand(cmd, dir) {
    // a blob packet
    if (cmd instanceof ArrayBuffer) {
      // todo more blob types to support?
      if (undefined === dir) {
        throw Error("no dir for a blob packet")
      }
      this.out.postMessage(
        {
          dir: dir,
          blob: cmd,
        },
        [cmd] // transfer it
      )
      return
    }

    if ("string" !== typeof cmd) {
      throw Error("unsupported cmd type: " + typeof cmd)
    }

    // to some identified channel
    if (undefined !== dir) {
      this.out.postMessage({
        dir: dir,
        src: cmd,
      })
      return
    }

    // to the default channel
    this.out.postMessage(cmd)
  }

  p2c(dir, cmd) {
    this.postCommand(cmd, dir)
  }
}

/**
 * A Nedh MessageChannel server listens on a window, accepting incoming
 * connections.
 */
export class McServer {
  constructor(listenOn, serviceName, landerFactory, clientInit) {
    listenOn.addEventListener(
      "message",
      function (me) {
        if ("object" !== typeof me.data) {
          return // not of interest
        }
        const { nedhService } = me.data
        if (nedhService !== serviceName) {
          return // not of interest
        }
        const connRequest = me.data

        me.preventDefault()
        me.stopImmediatePropagation()

        const [portIn, portOut] = me.ports
        const lander = landerFactory(connRequest)
        const peer = new McPeer(portIn, portOut, lander)
        if (undefined !== clientInit) {
          clientInit(connRequest, peer)
        }
      },
      true
    )
  }
}

/**
 * A Nedh MessageChannel client connects to a server listening on some window,
 * by offering the `MessagePort` pair as transport for the server, it
 * establishes the connection.
 */
export class McClient {
  constructor(connTarget, serviceName, lander, extraInfo = {}) {
    const uplink = new MessageChannel()
    const dnlink = new MessageChannel()
    this.peer = new McPeer(dnlink.port1, uplink.port2, lander)
    const svrPorts = [uplink.port1, dnlink.port2]
    connTarget.postMessage(
      Object.assign(
        {
          nedhService: serviceName,
        },
        extraInfo
      ),
      "*",
      svrPorts
    )
  }
}
