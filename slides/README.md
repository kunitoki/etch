
## Export reveal.js to pdf

```bash
npm install -g decktape

cd slides/presentation

python3 -m http.server

decktape reveal http://[::]:8000/index.html slides.pdf
```
