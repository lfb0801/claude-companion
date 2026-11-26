# Third-party attribution

Physics approach adapted from OpenWhip by GitFrog1111 and contributors:
https://github.com/GitFrog1111/OpenWhip
OpenWhip declares the MIT license in its package.json. Its repository does not supply a separate copyright notice in the inspected root. Attribution is retained here for the original JavaScript physics implementation.

Also informed by Victor Effects by Victor Rentea:
https://github.com/victorrentea/victor-effects
The following upstream MIT notice is retained for this adaptation.

MIT License

Copyright (c) 2026 Victor Rentea

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Clawd artwork

The PNG sprites in `assets/claude/` were rendered directly from Victor Effects' `ClawdArt` in `Sources/VictorEffects/ClawdMood.swift`, using its happy, scared, and dizzy moods and three boil frames. Source: https://github.com/victorrentea/victor-effects/blob/main/Sources/VictorEffects/ClawdMood.swift

The upstream Victor Rentea MIT notice above applies. Victor credits the model sheet and facial design to John Heibel's ClaudeAnimationBase: https://github.com/JohnHeibel/ClaudeAnimationBase . Its notice follows.

MIT License

Copyright (c) 2026 John Heibel

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Audio cues (not MIT-licensed)

The two short sound cues are third-party material. They are **not** covered by this project's MIT licence, and they remain the property of their rights holders.

- `assets/audio/little-friend.mp3` (also `mac/Sources/Companion/Resources/little-friend.mp3`) is a short excerpt of the movie Scarface (1983), downloaded from https://www.myinstants.com/en/instant/say-hello-to-my-lil-friend-636/ . Movie audio retains its original rights. It plays when the cannon is armed.
- `assets/audio/whip-summon.mp3` (also `mac/Sources/Companion/Resources/whip-summon.mp3`) is the first 0.65 s of the "cool hwhip" clip from myinstants.com, a user upload with no stated licence. It plays when the whip is summoned.

The cues are optional. Delete both files from those two folders and the app runs without them; every other sound is synthesized in code. If you hold the rights to either clip and want it removed, open an issue and it will be taken down.
