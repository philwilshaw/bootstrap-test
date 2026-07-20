import os

from flask import Flask, render_template

app = Flask(__name__)

ENVIRONMENT = os.environ.get("ENVIRONMENT", "local")


@app.route("/")
def home():
    return render_template("index.html", environment=ENVIRONMENT)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8080)))
