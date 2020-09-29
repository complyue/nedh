/**
  Nedh Peer Interface over WebSocket
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
    this.eol.finally(() => {
      // mark all channels end-of-stream on peer end-of-life
      for (const ch of this.channels.values()) {
        ch.publish(null);
      }
    });

    this._dir = null;
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
    ws.onmessage = (me) => {
      const pktData = me.data;
      const dir = this._dir;
      // a channel directive is effective only for the immediated following
      // packet, reset it anyway here
      this._dir = null;

      // case of a blob packet
      if (pktData instanceof ArrayBuffer) {
        if (null === dir) {
          throw Error("Nedh usage error: blob posted to default channel");
        }
        const ch = this.channels[dir];
        if (!(ch instanceof EventSink)) {
          throw Error("Nedh usage error: bad channel locator - " + dir);
        }
        ch.publish(pktData);
        return;
      }
      if ("string" !== typeof pktData) {
        debugger;
        throw "WS msg of type " + typeof pktData + " ?!";
      }

      // case of a channel directive packet
      const dirMatch = /^\[\#(.+)\]$/.exec(pktData);
      if (null !== dirMatch) {
        const [_, dirSrc] = dirMatch;
        dir = lander(dirSrc, undefined);
        return;
      }

      // case of a command packet
      const cmdVal = lander(pktData, dir);
      if (null === dir) {
        // to the default channel, no more to do
        return;
      }
      // publish to sink of specified channel
      const ch = this.channels[dir];
      if (!(ch instanceof EventSink)) {
        throw Error("Nedh usage error: bad channel locator - " + dir);
      }
      ch.publish(cmdVal);
    };
  }

  stop() {
    this.ws.close();
  }

  armedChannel(chLctr) {
    return this.channels[chLctr];
  }

  ensureChannel(chLctr) {
    if (undefined === this.channels[chLctr]) {
      this.channels[chLctr] = new EventSink();
    }
  }

  armChannel(chLctr, chSink) {
    if (undefined === chSink) {
      chSink = new EventSink();
    }
    this.channels[chLctr] = chSink;
  }

  postCommand(src, dir) {
    if (undefined !== dir) {
      let dirRepr;
      if ("string" === typeof dir) {
        dirRepr = JSON.stringify(dir);
      } else {
        dirRepr = "" + dir;
      }
      this.ws.send("[#" + dirRepr + "]");
    }
    this.ws.send("" + src);
  }

  p2c(dir, src) {
    this.postCommand(dir, src);
  }
}
