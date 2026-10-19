#!/bin/bash
# Synthetic airport babble (8 far-field talkers + hall noise, 40 s, 16 kHz PCM16) and two spoken
# questions, for relay/probe_vad.py's noisy-room runs:
#   scripts/make_babble_fixture.sh /tmp/vad && cd /tmp/vad
#   ~/.hermes/hermes-agent/venv/bin/python <repo>/relay/probe_vad.py q2.pcm --bg babble.pcm --noise -27 --lead 2 --tail 10 [--client]
# -27 dBFS babble is ~8 dB under the questions (say's level). Server VAD never answers there;
# --client (Otto's noisy-room turns) answers ~2.3 s after the question ends.
set -euo pipefail
out=${1:?output dir}
mkdir -p "$out" && cd "$out"
texts=("Our flight was delayed again so we went to get coffee near gate twelve and the line was huge."
  "I told him the meeting moved to Thursday but he never reads his email, honestly it is ridiculous."
  "Do you have the boarding passes or did you leave them in the car with the passports and the snacks?"
  "The kids want pizza but there is only that sandwich place open at this hour, which is fine I guess."
  "Last time we flew through here the security line took almost an hour and we nearly missed it."
  "She said the hotel has a pool and a gym and breakfast is included which is nice for the price."
  "Can you check if the train from the airport runs after midnight, I think it stops at eleven thirty."
  "We should call your mother when we land, she worries if she does not hear from us right away.")
voices=("Eddy (English (US))" "Flo (English (US))" "Grandpa (English (US))" "Fred" "Daniel (English (UK))"
  "Grandma (English (UK))" "Albert" "Eddy (English (UK))")
inputs=() filt=""
for i in 0 1 2 3 4 5 6 7; do
  say -v "${voices[$i]}" -o t$i.aiff "${texts[$i]} ${texts[$(( (i+3)%8 ))]} ${texts[$(( (i+5)%8 ))]}"
  inputs+=(-i t$i.aiff)
  filt="$filt[$i:a]aresample=16000,adelay=$(( i*700 )),lowpass=f=3200,aecho=0.8:0.6:40|70:0.35|0.25,aloop=loop=2:size=2e6[a$i];"
done
ffmpeg -y -loglevel error "${inputs[@]}" -filter_complex \
  "${filt}[a0][a1][a2][a3][a4][a5][a6][a7]amix=inputs=8:normalize=0,atrim=0:40[b];anoisesrc=d=40:c=pink:a=0.02:r=16000[n];[b][n]amix=inputs=2:normalize=0" \
  -ar 16000 -ac 1 -f s16le babble.pcm
say -v "Eddy (English (US))" -o q.aiff "What's the weather going to be like in Lisbon tomorrow?"
say -v "Eddy (English (US))" -o q2.aiff "Can you check what time my flight to Lisbon boards tomorrow, and remind me an hour before?"
for f in q q2; do ffmpeg -y -loglevel error -i $f.aiff -ar 16000 -ac 1 -f s16le $f.pcm; done
rm -f t?.aiff q.aiff q2.aiff
echo "wrote $out/babble.pcm q.pcm q2.pcm"
