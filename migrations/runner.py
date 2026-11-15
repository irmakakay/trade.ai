import hashlib
import os
import sys
from pathlib import Path
import psycopg

LOCK_ID = 948271

def get_conn_str() -> str:
    host = os.getenv("POSTGRES_HOST", "localhost")
    port = os.getenv("POSTGRES_PORT", "5432")
    db = os.getenv("POSTGRES_DB", "quantcore")
    user = os.getenv("POSTGRES_USER", "quant")
    pw = os.getenv("POSTGRES_PASSWORD", "quant_secret")
    return f"host={host} port={port} dbname={db} user={user} password={pw}"

def run_migrations() -> None:
    versions_dir = Path(__file__).parent / "versions"
    sql_files = sorted(versions_dir.glob("V*__*.sql"))

    with psycopg.connect(get_conn_str(), autocommit=False) as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT pg_advisory_lock(%s);", (LOCK_ID,))
            try:
                cur.execute("""
                    CREATE TABLE IF NOT EXISTS schema_migrations (
                        version VARCHAR(64) PRIMARY KEY,
                        checksum VARCHAR(64) NOT NULL,
                        applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
                    );
                """)
                conn.commit()

                for sql_file in sql_files:
                    version = sql_file.name.split("__")[0]
                    content = sql_file.read_text(encoding="utf-8")
                    checksum = hashlib.sha256(content.encode("utf-8")).hexdigest()

                    cur.execute("SELECT checksum FROM schema_migrations WHERE version = %s;", (version,))
                    row = cur.fetchone()
                    if row:
                        if row[0] != checksum:
                            raise RuntimeError(f"Checksum mismatch for {sql_file.name}")
                        print(f"[SKIP] {sql_file.name} already applied.")
                        continue

                    print(f"[APPLY] Applying {sql_file.name}...")
                    cur.execute(content)
                    cur.execute(
                        "INSERT INTO schema_migrations (version, checksum) VALUES (%s, %s);",
                        (version, checksum),
                    )
                    conn.commit()
                    print(f"[OK] {sql_file.name} committed.")
            finally:
                cur.execute("SELECT pg_advisory_unlock(%s);", (LOCK_ID,))
                conn.commit()

if __name__ == "__main__":
    try:
        run_migrations()
    except Exception as exc:
        print(f"[FATAL] Migration failed: {exc}", file=sys.stderr)
        sys.exit(1)
