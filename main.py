import os

from flask import Flask

app = Flask(__name__)

ENVIRONMENT = os.environ.get("ENVIRONMENT", "local")


@app.route("/")
def hello():
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>bootstrap-test — Hello World</title>
  <style>
    body {{
      font-family: system-ui, sans-serif;
      margin: 0;
      min-height: 100vh;
      display: grid;
      place-items: center;
      background: linear-gradient(160deg, #0f172a 0%, #1e293b 45%, #312e81 100%);
      color: #e2e8f0;
    }}
    main {{ text-align: center; padding: 2rem; }}
    h1 {{ font-size: clamp(2rem, 5vw, 3rem); margin-bottom: 0.5rem; }}
    .env {{
      display: inline-block;
      margin-top: 1rem;
      padding: 0.35rem 0.85rem;
      border-radius: 999px;
      background: rgba(255, 255, 255, 0.12);
      font-size: 0.95rem;
      letter-spacing: 0.04em;
      text-transform: uppercase;
    }}
  </style>
</head>
<body>
  <main>
    <h1>Hello, World!</h1>
    <p>Welcome to bootstrap-test.</p>
    <span class="env">{ENVIRONMENT}</span>
  </main>
</body>
</html>"""


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8080)))