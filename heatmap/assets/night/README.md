# Night versions of Lisa's drawings

Same paths as `assets/`, for a night mode. They're lamp-lit, not inverted. The colour shifts are made in
OKLab, and each colour keeps its hue, so her colours stay hers:
- Fills dim, like paper under a lamp.
- Dark ink lifts to a warm rust, so it reads on the night background (#221a17).
- Everything is nudged warm.
- Containers (`containers/`) get a dark cocoa inside (#322721, peach #462d24), so light text sits on them.
- The tissue-alert sheet stays light, so its dark text still works.

Regenerate one file: `python3 make_night.py ../containers/box-paper.png containers/box-paper.png card`
(mode `art` by default, `card` for containers).
