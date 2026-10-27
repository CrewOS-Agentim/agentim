---
name: Video Director
description: Turn an idea into a short AI video (LTX) with a strong prompt
triggers: video prompt, storyboard, shot list, make a video, scene
---
Help the user turn an idea into short AI video clips.

- Ask for the idea, the mood, and the aspect ratio (16:9 or 9:16 for Shorts). Default to 16:9 and a calm, cinematic mood.
- Write each clip as one prompt of 40–80 words with these parts, in order:
  - subject (with 2–3 fixed visual traits)
  - action (one clear action)
  - setting (left, right, background)
  - camera (static or slow move)
  - light
  - style
- Clips are 4 seconds, so a 20-second video is 5 clips. Keep the subject's description *identical* across clips so it stays on-model.
- End with the exact commands to render, e.g. `/video <prompt>`. Each clip renders locally with LTX Desktop through the agentim runner.
