/**
  machinery for packet landing
 */

export class Lander {
  constructor() {
    // initialize the packet stream
    const nxt = [null, null, null, null, null];
    nxt[0] = new Promise((resolve, reject) => {
      nxt[1] = resolve;
      nxt[2] = reject;
    });
    nxt[3] = new Promise((resolve, _reject) => {
      nxt[4] = resolve; // the injector
    });
    this.nxt = nxt;

    // spawn the landing thread
    this.landingThread().catch(console.error);
  }

  terminate() {
    if (null === this.nxt) {
      return;
    }
    const [_outlet, _resolve, _reject, _intake, _inject] = this.nxt;
    _inject([null, null]);
  }

  async land(pktSrc, _dir) {
    if (null === this.nxt) {
      throw Error("bug: lander already terminated.");
    }
    const [_outlet, _resolve, _reject, _intake, _inject] = this.nxt;
    const nxt = [null, null, null, null, null];
    nxt[0] = new Promise((resolve, reject) => {
      nxt[1] = resolve;
      nxt[2] = reject;
    });
    nxt[3] = new Promise((resolve, _reject) => {
      nxt[4] = resolve;
    });
    _inject([pktSrc, nxt]);
    return await _outlet;
  }

  async landingThread() {
    // XXX a subclass of Lander normally overrides this method, with even
    //     verbatim copy of the method code here, it's already very useful,
    //     in that the subclass' lexical context becomes the landing
    //     environment.
    //
    //     And as this function's scope is the local scope within which the
    //     source of incoming packets are eval'ed, other forms of (maybe ugly
    //     and nasty) hacks can be put right here, but god forbid it.

    if (null === this.nxt) {
      throw Error("Passed end-of-stream for packets");
    }
    while (true) {
      const [_outlet, _resolve, _reject, _intake, _inject] = this.nxt;
      const [_src, _nxt] = await _intake;
      this.nxt = _nxt;
      if (null === _src) {
        if (null !== _nxt) {
          throw Error("bug: inconsistent eos signal");
        }
        return; // reached end-of-stream, terminate this thread
      }
      if (null === _nxt) {
        throw Error("bug: null nxt for non-eos-packet");
      }

      // land one packet
      try {
        _resolve(await eval(`((async()=>{ ${_src} })())`));
      } catch (exc) {
        _reject(exc);
      }
    }
  }
}
