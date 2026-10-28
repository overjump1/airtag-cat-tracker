'use strict';
// Frida script — inject into `locationd` on a jailbroken iPhone.
//
// HOW IT WORKS
// ─────────────────────────────────────────────────────────────────
// 1. Hook -[CLDurianService performTask:forClient:onDevice:] to capture
//    the live service/client/device pointers the first time any task runs.
// 2. After capture, we can drive the AirTag ourselves via those pointers.
// 3. Hook CBPeripheral internals to read RSSI from the existing L2CAP
//    connection — no UWB needed, just Bluetooth signal strength.
//
// PREREQUISITE
// ─────────────────────────────────────────────────────────────────
// Play a sound ONCE via the Find My app → that fires the hook and captures
// the DurianService.  After that, this script owns the controls.

// ── State ──────────────────────────────────────────────────────────
var _svc = null;   // CLDurianService *
var _cli = null;   // client id
var _dev = null;   // CLDurianDevice *
var _rssi = null;  // latest RSSI (dBm)
var _rssiTs = 0;   // epoch ms of last RSSI reading

// ── Helpers ────────────────────────────────────────────────────────
function onMain(fn) {
  ObjC.schedule(ObjC.mainQueue, fn);
}

// ── Hook 1: capture DurianService on first task execution ──────────
function hookService() {
  const cls = ObjC.classes.CLDurianService;
  if (!cls) {
    console.log('[airtag] CLDurianService not found in locationd — wrong process?');
    return false;
  }
  const method = cls['- performTask:forClient:onDevice:'];
  if (!method) {
    console.log('[airtag] performTask:forClient:onDevice: selector not found');
    return false;
  }
  Interceptor.attach(method.implementation, {
    onEnter(args) {
      if (_svc === null) {
        _svc = args[0];
        _cli = args[3];
        _dev = args[4];
        console.log('[airtag] ✓ DurianService captured — full control enabled');
      }
    }
  });
  console.log('[airtag] Hook 1 active: waiting for first Find My sound to capture service');
  return true;
}

// ── Hook 2: capture RSSI updates from CBPeripheral ─────────────────
function hookRSSI() {
  const CBPeripheral = ObjC.classes.CBPeripheral;
  if (!CBPeripheral) { return false; }

  // iOS calls -[CBPeripheral didReadRSSI:error:] internally after readRSSI.
  // Some older builds use _peripheralDidUpdateRSSI:error:.  Try both.
  const selNames = [
    '- didReadRSSI:error:',
    '- _peripheralDidUpdateRSSI:error:',
  ];
  for (const sel of selNames) {
    const m = CBPeripheral[sel];
    if (!m) { continue; }
    Interceptor.attach(m.implementation, {
      onEnter(args) {
        // args[2] = NSNumber (RSSI) or NSError for error variant
        try {
          const val = new ObjC.Object(args[2]);
          const n = parseInt(val.toString(), 10);
          if (!isNaN(n) && n < 0) {   // valid RSSI is negative
            _rssi = n;
            _rssiTs = Date.now();
          }
        } catch (_) {}
      }
    });
    console.log('[airtag] Hook 2 active: RSSI via ' + sel);
    return true;
  }
  console.log('[airtag] RSSI hook not found — values will stay null');
  return false;
}

// ── Task builders ──────────────────────────────────────────────────
// CLDurianTask exposes factory class methods whose names ARE the task names:
//   +stopSoundTask, +startSoundTask, +startSoundSequenceTaskWithSequence:, …
function makeTaskByName(name) {
  const T = ObjC.classes.CLDurianTask;
  const m = T['+ ' + name];
  if (!m) { throw new Error('Unknown task: ' + name); }
  return m.call(T);
}

// Build a sound-sequence task from a raw byte array.
// sequence: [seqId, repeat, offset, pause]  — e.g. [0, 3, 0, 0]
function makeSoundSequenceTask(seq) {
  const T = ObjC.classes.CLDurianTask;
  const NSData = ObjC.classes.NSData;
  const buf = Memory.alloc(seq.length);
  buf.writeByteArray(seq);
  const data = NSData.dataWithBytes_length_(buf, seq.length);

  // iOS 18.2+ renamed the factory
  const newSel = '+ startSoundSequenceTaskWithEncodedSequence:';
  const oldSel = '+ startSoundSequenceTaskWithSequence:';
  const factory = T[newSel] || T[oldSel];
  if (!factory) { throw new Error('startSoundSequenceTask factory not found'); }
  return factory.call(T, data);
}

// ── Execute a built task ───────────────────────────────────────────
function runTask(task) {
  if (_svc === null) {
    throw new Error('DurianService not ready — play a sound via Find My first');
  }
  const svc = new ObjC.Object(_svc);
  const cli = new ObjC.Object(_cli);
  const dev = new ObjC.Object(_dev);
  svc.performTask_forClient_onDevice_(task, cli, dev);
}

// ── RSSI read trigger ──────────────────────────────────────────────
// Walk all live CBPeripheral instances; call readRSSI on connected ones.
function triggerRSSIRead() {
  ObjC.choose(ObjC.classes.CBPeripheral, {
    onMatch(p) {
      try {
        const peripheral = new ObjC.Object(p.handle);
        // CBPeripheralStateConnected = 2
        if (parseInt(peripheral.state()) === 2) {
          peripheral.readRSSI();
        }
      } catch (_) {}
    },
    onComplete() {}
  });
}

// ── RPC exports (called from Python controller) ────────────────────
rpc.exports = {
  // Call once after injection; returns which hooks succeeded.
  setup() {
    const s = hookService();
    const r = hookRSSI();
    return { serviceHook: s, rssiHook: r };
  },

  // True once Find My has been used once and DurianService is captured.
  isReady() {
    return _svc !== null;
  },

  // Play the default AirTag alert sound.
  playSound() {
    onMain(() => {
      try {
        // Sequence 0 = default alert, repeat 3×, no offset, no gap
        const task = makeSoundSequenceTask([0, 3, 0, 0]);
        runTask(task);
      } catch (e) {
        // Fallback: if sequence task isn't available, try raw opcode 40
        // [40, seqId=0, repeat=3, offset=0, pause=0]
        console.log('[airtag] sequence task failed (' + e.message + '), trying raw opcode');
        try {
          const T = ObjC.classes.CLDurianTask;
          const NSData = ObjC.classes.NSData;
          const bytes = [40, 0, 3, 0, 0];
          const buf = Memory.alloc(bytes.length);
          buf.writeByteArray(bytes);
          const data = NSData.dataWithBytes_length_(buf, bytes.length);
          const cmd = ObjC.classes.CLDurianCommand.alloc().initWithData_(data);
          const task2 = ObjC.classes.CLDurianTask.alloc().initWithCommand_(cmd);
          runTask(task2);
        } catch (e2) {
          console.log('[airtag] playSound fallback also failed: ' + e2.message);
        }
      }
    });
    return 'ok';
  },

  // Stop any currently playing sound.
  stopSound() {
    onMain(() => {
      try { runTask(makeTaskByName('stopSoundTask')); }
      catch (e) { console.log('[airtag] stopSound: ' + e.message); }
    });
    return 'ok';
  },

  // Trigger an async RSSI read; result shows up in the next getRSSI call.
  requestRSSI() {
    onMain(triggerRSSIRead);
    return 'requested';
  },

  // Return the most recent RSSI reading (may be null until first read).
  getRSSI() {
    return {
      rssi:   _rssi,
      age_ms: _rssi !== null ? Date.now() - _rssiTs : null,
    };
  },
};

console.log('[airtag] hook loaded — call rpc.exports.setup() to activate');
