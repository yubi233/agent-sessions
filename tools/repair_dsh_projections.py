#!/usr/bin/env python3
"""只修正已确证同源的 DSH 重复投影；默认只读，保留全部会话与事件。"""

import argparse
import collections
import datetime
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import sys


USER_ACTIONS = ("session.start", "session.resume", "session.send")
TERMINAL_COMMAND_STATES = ("succeeded", "failed", "rejected", "cancelled", "expired")


def connect(path, readonly=True):
    path = Path(path).resolve(strict=True)
    db = sqlite3.connect(path.as_uri() + ("?mode=ro" if readonly else "?mode=rw"), uri=True)
    db.row_factory = sqlite3.Row
    if readonly:
        db.execute("PRAGMA query_only=ON")
    db.execute("PRAGMA busy_timeout=10000")
    return db


def columns(db, table):
    return {row[1] for row in db.execute(f"PRAGMA table_info({table})")}


def inspect(relay, daemon):
    session_columns = columns(relay, "sessions")
    rows = {
        row["id"]: dict(row)
        for row in relay.execute(
            "SELECT s.*, w.terminal_id FROM sessions s JOIN workspaces w ON w.id=s.workspace_id "
            "WHERE s.provider='dsh'"
        )
    }
    groups = collections.defaultdict(list)
    local = dict(daemon.execute("SELECT key,value FROM local_state"))
    for session_id, row in rows.items():
        raw = local.get("instance:" + session_id)
        if not raw:
            continue
        try:
            mapping = json.loads(raw)
        except (TypeError, ValueError):
            continue
        if not isinstance(mapping, dict) or mapping.get("provider") != "dsh":
            continue
        root, source = mapping.get("workspace_root"), mapping.get("instance_id")
        if not isinstance(root, str) or not root or not isinstance(source, str) or not source:
            continue
        row["mapping_raw"] = raw
        row["root"], row["source"] = root, source
        row["actions"] = relay.execute(
            "SELECT count(*) FROM commands WHERE session_id=? AND kind IN (?,?,?)",
            (session_id, *USER_ACTIONS),
        ).fetchone()[0]
        row["created_events"] = relay.execute(
            "SELECT count(*) FROM session_events WHERE session_id=? AND event_type='session.created'",
            (session_id,),
        ).fetchone()[0]
        row["event_count"] = relay.execute(
            "SELECT count(*) FROM session_events WHERE session_id=?", (session_id,)
        ).fetchone()[0]
        groups[(root, source)].append(row)

    changes, conflicts = [], []
    for (root, source), candidates in sorted(groups.items()):
        if len(candidates) < 2:
            continue
        source_hash = hashlib.sha256(json.dumps([root, source]).encode()).hexdigest()[:16]
        identities = {(r["account_id"], r["workspace_id"], r["terminal_id"]) for r in candidates}
        owners = [r for r in candidates if r["created_events"] and r["actions"]]
        reason = None
        if len(identities) != 1:
            reason = "scope_mismatch"
        elif len(owners) != 1:
            reason = "canonical_not_unique"
        else:
            canonical = owners[0]
            extras = [r for r in candidates if r["id"] != canonical["id"]]
            if any(r["actions"] or r["created_events"] for r in extras):
                reason = "duplicate_has_independent_activity"
            elif canonical.get("visibility", "default") != "default" or canonical["archived_at_unix_ms"]:
                reason = "canonical_not_visible"
            elif any(r["status"] not in ("idle", "stopped", "completed", "failed") for r in candidates):
                reason = "session_not_quiescent"
            else:
                thread_key = "dshthread:" + root + ":" + source
                previous = local.get(thread_key)
                if previous not in {r["id"] for r in candidates}:
                    reason = "reverse_mapping_not_in_group"
                elif any(
                    r.get("visibility") != "duplicate" and r["id"] != previous
                    for r in extras
                ):
                    reason = "unproven_import_projection"
                elif all(r.get("visibility") == "duplicate" for r in extras) and previous == canonical["id"]:
                    continue
                else:
                    changes.append({
                        "source_hash": source_hash,
                        "canonical": canonical["id"],
                        "duplicates": [r["id"] for r in extras],
                        "thread_key": thread_key,
                        "previous_thread": previous,
                        "mapping_raw": {r["id"]: r["mapping_raw"] for r in candidates},
                        "before": {
                            r["id"]: {
                                "origin": r.get("origin", "managed"),
                                "visibility": r.get("visibility", "default"),
                                "event_count": r["event_count"],
                                "last_seq": r["last_seq"],
                            } for r in candidates
                        },
                    })
        if reason:
            conflicts.append({"source_hash": source_hash, "reason": reason,
                              "sessions": [r["id"] for r in candidates]})
    return {
        "schema_ready": {"origin", "visibility"} <= session_columns,
        "sessions": len(rows),
        "unique_sources": len(groups),
        "changes": changes,
        "conflicts": conflicts,
    }


def public_plan(plan):
    return {
        "schema_ready": plan["schema_ready"], "sessions": plan["sessions"],
        "unique_sources": plan["unique_sources"],
        "duplicate_groups": len(plan["changes"]),
        "duplicates_to_hide": sum(len(x["duplicates"]) for x in plan["changes"]),
        "groups": [
            {k: x[k] for k in ("source_hash", "canonical", "duplicates")}
            for x in plan["changes"]
        ],
        "conflicts": plan["conflicts"],
    }


def ensure_quiescent(relay):
    placeholders = ",".join("?" for _ in TERMINAL_COMMAND_STATES)
    count = relay.execute(
        f"SELECT count(*) FROM commands WHERE status NOT IN ({placeholders})",
        TERMINAL_COMMAND_STATES,
    ).fetchone()[0]
    if count:
        raise ValueError("存在未收口命令，拒绝修改映射；请等待收口并停止服务")


def save_private(path, value):
    with open(path, "x", encoding="utf-8") as stream:
        os.chmod(path, 0o600)
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write("\n")


def backup(source, target):
    fd = os.open(target, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    os.close(fd)
    with sqlite3.connect(target) as dest:
        source.backup(dest)


def apply(relay_path, daemon_path, backup_dir):
    with connect(relay_path) as relay, connect(daemon_path) as daemon:
        ensure_quiescent(relay)
        plan = inspect(relay, daemon)
        if not plan["schema_ready"]:
            raise ValueError("Relay 尚未完成 origin/visibility 迁移，拒绝写入")
        if plan["conflicts"]:
            raise ValueError("存在无法安全自动修正的同源冲突，请先检查只读报告")
        if not plan["changes"]:
            return {"applied": False, "reason": "already_consistent", **public_plan(plan)}
        directory = Path(backup_dir).resolve()
        directory.mkdir(mode=0o700, parents=True, exist_ok=False)
        backup(relay, directory / "relay.db")
        backup(daemon, directory / "daemon.db")
        save_private(directory / "repair-journal.json", {
            "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "relay_path": str(Path(relay_path).resolve()),
            "daemon_path": str(Path(daemon_path).resolve()), "plan": plan,
        })

    with connect(relay_path, False) as relay, connect(daemon_path, False) as daemon:
        relay.execute("BEGIN IMMEDIATE")
        daemon.execute("BEGIN IMMEDIATE")
        ensure_quiescent(relay)
        if inspect(relay, daemon) != plan:
            raise ValueError("备份后状态发生变化，已拒绝写入；请重新预检")
        for change in plan["changes"]:
            for sid in change["duplicates"]:
                relay.execute(
                    "UPDATE sessions SET origin='dsh_import',visibility='duplicate' WHERE id=?", (sid,)
                )
            updated = daemon.execute(
                "UPDATE local_state SET value=? WHERE key=? AND value=?",
                (change["canonical"], change["thread_key"], change["previous_thread"]),
            ).rowcount
            if updated != 1:
                raise ValueError("映射比较失败，已拒绝写入")
        # 两库 WAL 不能保证跨库崩溃原子性；先隐藏副本，再改反向映射，保留前置快照供恢复。
        relay.commit()
        daemon.commit()
    return {"applied": True, "backup_dir": str(directory), **public_plan(plan)}


def restore(journal_path):
    journal_path = Path(journal_path).resolve(strict=True)
    journal = json.loads(journal_path.read_text())
    with connect(journal["relay_path"], False) as relay, connect(journal["daemon_path"], False) as daemon:
        relay.execute("BEGIN IMMEDIATE")
        daemon.execute("BEGIN IMMEDIATE")
        ensure_quiescent(relay)
        for change in journal["plan"]["changes"]:
            current = daemon.execute("SELECT value FROM local_state WHERE key=?", (change["thread_key"],)).fetchone()
            if not current or current[0] not in (change["canonical"], change["previous_thread"]):
                raise ValueError("反向映射已被其他操作修改，拒绝回滚")
            for sid, old_mapping in change["mapping_raw"].items():
                mapping = daemon.execute("SELECT value FROM local_state WHERE key=?", ("instance:" + sid,)).fetchone()
                if not mapping or mapping[0] != old_mapping:
                    raise ValueError("底层实例绑定发生变化，拒绝回滚")
            for sid in change["duplicates"]:
                before = change["before"][sid]
                row = relay.execute("SELECT origin,visibility,last_seq FROM sessions WHERE id=?", (sid,)).fetchone()
                events = relay.execute("SELECT count(*) FROM session_events WHERE session_id=?", (sid,)).fetchone()[0]
                if not row or row["visibility"] not in ("duplicate", before["visibility"]) or row["last_seq"] != before["last_seq"] or events != before["event_count"]:
                    raise ValueError("副本在修正后发生变化，拒绝覆盖回滚")
                relay.execute("UPDATE sessions SET origin=?,visibility=? WHERE id=?",
                              (before["origin"], before["visibility"], sid))
            daemon.execute("UPDATE local_state SET value=? WHERE key=?",
                           (change["previous_thread"], change["thread_key"]))
        daemon.commit()
        relay.commit()
    return {"restored": True, "groups": len(journal["plan"]["changes"])}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--relay-db")
    parser.add_argument("--daemon-db")
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--services-stopped", action="store_true",
                        help="仅在确认目标 Relay/daemon 已停止后使用")
    parser.add_argument("--backup-dir")
    parser.add_argument("--restore-journal")
    args = parser.parse_args()
    try:
        if args.restore_journal:
            if args.apply or not args.services_stopped:
                parser.error("回滚需要 --services-stopped，且不能同时 --apply")
            result = restore(args.restore_journal)
        else:
            if not args.relay_db or not args.daemon_db:
                parser.error("需要 --relay-db 和 --daemon-db")
            if args.apply:
                if not args.services_stopped or not args.backup_dir:
                    parser.error("写入需要 --services-stopped 和全新的 --backup-dir")
                result = apply(args.relay_db, args.daemon_db, args.backup_dir)
            else:
                with connect(args.relay_db) as relay, connect(args.daemon_db) as daemon:
                    result = public_plan(inspect(relay, daemon))
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except (ValueError, OSError, sqlite3.Error) as exc:
        print(f"DSH projection repair refused: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
