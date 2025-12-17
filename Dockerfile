FROM python:3.10-slim

ENV PYTHONUNBUFFERED=1
WORKDIR /app

RUN pip install --no-cache-dir fastapi uvicorn requests python-dotenv

COPY main.py /app/main.py
COPY .env /app/.env

EXPOSE 5010

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "5010"]
