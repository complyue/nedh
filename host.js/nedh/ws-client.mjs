/**
 * Nedh Peer Interface on client site over WebSocket
 */

import { EventSink } from "edh";

export class WsPeer {
  constructor(wsUrl, lander) {
    this.lander = lander;
    this._openNotifs = [];
    this._closeNotifs = [];
    this.opened = new Promise((resolve, reject) => {
      this._openNotifs.push([resolve, reject]);
    });
    this.eol = new Promise((resolve, reject) => {
      this._closeNotifs.push([resolve, reject]);
    });
    this.channels = {};
    this.eol.finally(() => this.cleanup());

    this._chLctr = null;
    const ws = new WebSocket(wsUrl);
    this.ws = ws;
    ws.binaryType = "arraybuffer";
    ws.onopen = () => {
      for (const [resolve, _reject] of this._openNotifs) {
        resolve(this);
      }
    };
    ws.onerror = (ee) => {
      console.error("WS error:", ee);
      // onerror event doesn't contain description, defer handling to onclose
      // see: https://stackoverflow.com/a/18804298/6394508
    };
    ws.onclose = (ce) => {
      this.lander.terminate(); // terminate the lander anyway when ws closed

      console.debug("WS closed.", ce);
      if (1000 == ce.code || 1006 == ce.code) {
        for (const [resolve, _reject] of this._closeNotifs) {
          resolve(true);
        }
        for (const [_resolve, reject] of this._openNotifs) {
          reject(new Error("WS closed before open"));
        }
      } else {
        const msg =
          "WebSocket closed, code=" + ce.code + "  reason:" + ce.reason;
        this.handleError(msg);
        const err = new Error(msg);
        for (const [_resolve, reject] of this._closeNotifs) {
          reject(err);
        }
        for (const [_resolve, reject] of this._openNotifs) {
          reject(err);
        }
      }
    };
    ws.onmessage = async (me) => {
      const pktData = me.data;
      const chLctr = this._chLctr;
      // a packet directive a.k.a. channel locator, is effective only for the
      // immediated following packet, reset it anyway here
      this._chLctr = null;

      // case of a blob packet
      if (pktData instanceof ArrayBuffer) {
        if (null === chLctr) {
          throw Error("Nedh usage error: blob posted to default channel");
        }
        const ch = this.channels[chLctr];
        if (ch instanceof EventSink) {
          ch.publish(pktData);
        } else {
          console.error(
            "Nedh usage error: bad channel locator for a blob packet",
            chLctr
          );
        }
        return;
      }

      // otherwise it must in source form
      if ("string" !== typeof pktData) {
        debugger;
        throw Error("bug: WS msg of type " + typeof pktData);
      }

      // case of a packet directive / channel locator packet
      const dirMatch = /^\[\#(.+)\]$/.exec(pktData);
      if (null !== dirMatch) {
        const [_, dirSrc] = dirMatch;
        this._chLctr = await lander.land(dirSrc, undefined);
        return;
      }

      // case of a command packet
      const cmdVal = await lander.land(pktData, chLctr);
      if (null === chLctr) {
        // to the default channel, only side-effects desirable
        if (undefined !== cmdVal) {
          console.warn(
            "Some value resulted in the default channel: ",
            cmdVal,
            pktData
          );
        }
        return;
      }

      // publish to sink of specified channel
      const ch = this.channels[chLctr];
      if (ch instanceof EventSink) {
        ch.publish(cmdVal);
      } else {
        console.error("Nedh usage error: bad channel locator", chLctr);
      }
    };
  }

  cleanup() {
    // mark all channels end-of-stream on peer end-of-life
    for (const ch of Object.values(this.channels)) {
      ch.publish(null);
    }
  }

  async handleError(err, errDetails) {
    console.error(err, errDetails);
  }

  stop() {
    this.ws.close();
  }

  armedChannel(chLctr) {
    return this.channels[chLctr];
  }

  ensureChannel(chLctr) {
    let ch = this.channels[chLctr];
    if (undefined === ch) {
      ch = this.channels[chLctr] = new EventSink();
    }
    return ch;
  }

  armChannel(chLctr, chSink) {
    if (undefined === chSink) {
      chSink = new EventSink();
    } else if (!(chSink instanceof EventSink)) {
      throw Error("not an event sink: " + chSink);
    }
    this.channels[chLctr] = chSink;
  }

  postCommand(cmd, dir) {
    if (undefined !== dir) {
      let dirRepr;
      if ("string" === typeof dir) {
        dirRepr = JSON.stringify(dir);
      } else {
        dirRepr = "" + dir;
      }
      this.ws.send("[#" + dirRepr + "]");
    }
    this.ws.send(cmd);
  }

  p2c(dir, cmd) {
    this.postCommand(cmd, dir);
  }
}
