// Engine_Notetalk: PolyPerc-style synth + cut-bus analysis (amp, pitch) for softcut mode.
// Analysis reads from Crone cut bus (context.cut_b). Polls: amp_cut, pitch_cut, pitch_cut_conf.

Engine_Notetalk : CroneEngine {
  var pg;
  var amp=0.3;
  var release=0.5;
  var pw=0.5;
  var cutoff=1000;
  var gain=2;
  var pan=0;
  var cutBusIndex;
  var ampBus, pitchBus, confBus;
  var analysisSynth;

  *new { arg context, doneCallback;
    ^super.new(context, doneCallback);
  }

  alloc {
    cutBusIndex = context.cut_b ? 0;
    pg = ParGroup.tail(context.xg);

    // --- Synth (PolyPerc-style) ---
    SynthDef("NotetalkPerc", {
      arg out, freq = 440, pw=pw, amp=amp, cutoff=cutoff, gain=gain, release=release, pan=pan;
      var snd = Pulse.ar(freq, pw);
      var filt = MoogFF.ar(snd,cutoff,gain);
      var env = Env.perc(level: amp, releaseTime: release).kr(2);
      Out.ar(out, Pan2.ar((filt*env), pan));
    }).add;

    this.addCommand("hz", "f", { arg msg;
      var val = msg[1];
      Synth("NotetalkPerc", [\out, context.out_b, \freq,val,\pw,pw,\amp,amp,\cutoff,cutoff,\gain,gain,\release,release,\pan,pan], target:pg);
    });
    this.addCommand("amp", "f", { arg msg; amp = msg[1]; });
    this.addCommand("pw", "f", { arg msg; pw = msg[1]; });
    this.addCommand("release", "f", { arg msg; release = msg[1]; });
    this.addCommand("cutoff", "f", { arg msg; cutoff = msg[1]; });
    this.addCommand("gain", "f", { arg msg; gain = msg[1]; });
    this.addCommand("pan", "f", { arg msg; pan = msg[1]; });

    // --- Cut-bus analysis: read from bus, Amplitude + Pitch, write to control busses for polls ---
    ampBus = Bus.control(context.server, 1);
    pitchBus = Bus.control(context.server, 1);
    confBus = Bus.control(context.server, 1);

    SynthDef("NotetalkAnalysis", {
      arg cutBus=0, ampB=0, pitchB=0, confB=0;
      var in = In.ar(cutBus, 2).sum;
      var ampKr = Amplitude.kr(in, 0.01, 0.1);
      var pitch = Pitch.kr(in, ampThreshold: 0.02, peakThreshold: 0.5, minFreq: 50, maxFreq: 4000);
      Out.kr(ampB, ampKr);
      Out.kr(pitchB, pitch[0]);
      Out.kr(confB, pitch[1]);
    }).add;

    context.server.sync;

    analysisSynth = Synth("NotetalkAnalysis", [
      \cutBus, cutBusIndex,
      \ampB, ampBus.index,
      \pitchB, pitchBus.index,
      \confB, confBus.index
    ], target: context.xg);

    this.addCommand("setCutBus", "i", { arg msg;
      cutBusIndex = msg[1];
      if (analysisSynth.notNil) {
        analysisSynth.set(\cutBus, cutBusIndex);
      };
    });

    this.addPoll(\amp_cut, {
      ampBus.getSynchronous
    });
    this.addPoll(\pitch_cut, {
      pitchBus.getSynchronous
    });
    this.addPoll(\pitch_cut_conf, {
      confBus.getSynchronous
    });
  }

  free {
    if (analysisSynth.notNil) { analysisSynth.free; };
    ampBus.free;
    pitchBus.free;
    confBus.free;
    pg.free;
  }
}
