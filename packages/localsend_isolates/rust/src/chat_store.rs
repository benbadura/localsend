//! App-owned durable chat storage. No text is logged or retained in receipts.
use anyhow::{Result, bail, ensure};
use localsend::http::chat::{ChatReceipt, MAX_MESSAGE_BYTES, TTL_SECONDS};
use rusqlite::{Connection, OptionalExtension, params};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub struct ChatStore {
    inner: Mutex<Store>,
}
struct Store {
    db: Connection,
    deadlines: HashMap<(String, String, bool), Instant>,
}

#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "camelCase", rename_all_fields = "camelCase")]
enum Command {
    Conversations,
    Messages {
        peer: String,
        before: Option<i64>,
        search: String,
    },
    Trusted {
        peer: String,
    },
    Trust {
        peer: String,
        value: bool,
    },
    Receive {
        peer: String,
        alias: String,
        id: String,
        text: String,
        ttl: Option<u32>,
        approved: bool,
    },
    Create {
        peer: String,
        alias: String,
        id: String,
        text: String,
        ttl: Option<u32>,
    },
    Attempt {
        peer: String,
        id: String,
    },
    Status {
        peer: String,
        id: String,
        status: String,
    },
    Receipt {
        peer: String,
        id: String,
    },
    Confirm {
        peer: String,
        id: String,
        receipt: ChatReceipt,
    },
    Delete {
        peer: String,
        id: Option<String>,
    },
    Read {
        peer: String,
    },
    Purge,
}

pub fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

impl ChatStore {
    pub fn open(path: &str) -> Result<Self> {
        let db = Connection::open(path)?;
        let version: i64 = db.query_row("PRAGMA user_version", [], |row| row.get(0))?;
        ensure!(
            version <= 1,
            "Chat database version is newer than this application"
        );
        db.busy_timeout(Duration::from_secs(5))?;
        db.execute_batch("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; PRAGMA secure_delete=ON;
            CREATE TABLE IF NOT EXISTS peers(peer TEXT PRIMARY KEY, alias TEXT NOT NULL, trusted INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS messages(
                seq INTEGER PRIMARY KEY AUTOINCREMENT, peer TEXT NOT NULL, id TEXT NOT NULL, outgoing INTEGER NOT NULL,
                body TEXT, search_text TEXT, created INTEGER NOT NULL, delivered INTEGER, expires INTEGER, ttl INTEGER,
                status TEXT NOT NULL, unread INTEGER NOT NULL DEFAULT 0, UNIQUE(peer,id,outgoing));
            CREATE INDEX IF NOT EXISTS chat_page ON messages(peer,seq);
            CREATE INDEX IF NOT EXISTS chat_expiry ON messages(expires);
            PRAGMA user_version=1;
            UPDATE messages SET status='unconfirmed' WHERE outgoing=1 AND status='sending';")?;
        let mut deadlines = HashMap::new();
        let now = now_ms();
        {
            let mut stmt = db.prepare("SELECT peer,id,outgoing,expires,ttl FROM messages WHERE body IS NOT NULL AND expires IS NOT NULL")?;
            let rows = stmt.query_map([], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, bool>(2)?,
                    r.get::<_, i64>(3)?,
                    r.get::<_, u32>(4)?,
                ))
            })?;
            for row in rows {
                let (peer, id, outgoing, expires, ttl) = row?;
                deadlines.insert(
                    (peer, id, outgoing),
                    Instant::now()
                        + Duration::from_millis((expires - now).clamp(0, ttl as i64 * 1000) as u64),
                );
            }
        }
        let store = Self {
            inner: Mutex::new(Store { db, deadlines }),
        };
        store.command("{\"op\":\"purge\"}")?;
        Ok(store)
    }

    #[cfg(test)]
    pub(crate) fn command_at_for_test(&self, input: &str, now: i64) -> Result<String> {
        self.command_at(input, now)
    }
    pub fn command(&self, input: &str) -> Result<String> {
        self.command_at(input, now_ms())
    }
    fn command_at(&self, input: &str, now: i64) -> Result<String> {
        let cmd: Command = serde_json::from_str(input)?;
        let mut store = self
            .inner
            .lock()
            .map_err(|_| anyhow::anyhow!("Chat store unavailable"))?;
        store.purge(now)?;
        let result = store.run(cmd, now)?;
        Ok(serde_json::to_string(&result)?)
    }
}

impl Store {
    fn purge(&mut self, now: i64) -> Result<()> {
        self.db.execute("UPDATE messages SET body=NULL,search_text=NULL,status='expired',unread=0 WHERE body IS NOT NULL AND expires<=?", [now])?;
        let expired: Vec<_> = self
            .deadlines
            .iter()
            .filter(|(_, end)| **end <= Instant::now())
            .map(|(key, _)| key.clone())
            .collect();
        for (peer, id, outgoing) in &expired {
            self.db.execute("UPDATE messages SET body=NULL,search_text=NULL,status='expired',unread=0 WHERE peer=? AND id=? AND outgoing=? AND body IS NOT NULL", params![peer,id,outgoing])?;
            self.deadlines
                .remove(&(peer.clone(), id.clone(), *outgoing));
        }
        Ok(())
    }
    fn deadline(&mut self, peer: &str, id: &str, outgoing: bool, duration: i64) {
        self.deadlines.insert(
            (peer.into(), id.into(), outgoing),
            Instant::now() + Duration::from_millis(duration.max(0) as u64),
        );
    }
    fn receipt(&self, peer: &str, id: &str, now: i64) -> Result<Option<ChatReceipt>> {
        Ok(self.db.query_row("SELECT delivered,expires,status FROM messages WHERE peer=? AND id=? AND outgoing=0", params![peer,id], |r| {
            let expires: Option<i64> = r.get(1)?;
            let remaining = expires.map(|end| {
                let wall = (end-now).max(0);
                self.deadlines.get(&(peer.into(),id.into(),false)).map_or(wall, |deadline| wall.min(deadline.saturating_duration_since(Instant::now()).as_millis() as i64))
            });
            Ok(ChatReceipt { message_id: id.into(), delivered_at_ms: r.get(0)?, remaining_ttl_ms: remaining, status: r.get(2)? })
        }).optional()?)
    }
    fn run(&mut self, cmd: Command, now: i64) -> Result<Value> {
        match cmd {
            Command::Purge => Ok(json!(null)),
            Command::Trusted { peer } => Ok(json!(
                self.db
                    .query_row("SELECT trusted FROM peers WHERE peer=?", [peer], |r| r
                        .get::<_, bool>(0))
                    .optional()?
                    .unwrap_or(false)
            )),
            Command::Trust { peer, value } => {
                self.db.execute(
                    "UPDATE peers SET trusted=? WHERE peer=?",
                    params![value, peer],
                )?;
                Ok(json!(null))
            }
            Command::Conversations => {
                let mut stmt = self.db.prepare("SELECT p.peer,p.alias,p.trusted,MAX(m.created),SUM(m.unread) FROM peers p JOIN messages m ON m.peer=p.peer WHERE m.body IS NOT NULL GROUP BY p.peer ORDER BY MAX(m.seq) DESC")?;
                let rows = stmt.query_map([],|r| Ok(json!({"peer":r.get::<_,String>(0)?,"alias":r.get::<_,String>(1)?,"trusted":r.get::<_,bool>(2)?,"timestamp":r.get::<_,i64>(3)?,"unread":r.get::<_,i64>(4)?})))?;
                Ok(Value::Array(rows.collect::<rusqlite::Result<Vec<_>>>()?))
            }
            Command::Messages {
                peer,
                before,
                search,
            } => {
                let mut stmt = self.db.prepare("SELECT seq,id,body,outgoing,created,expires,ttl,status FROM messages WHERE peer=? AND body IS NOT NULL AND seq<? AND instr(search_text,?)>0 ORDER BY seq DESC LIMIT 50")?;
                let rows = stmt.query_map(params![peer,before.unwrap_or(i64::MAX),search.to_lowercase()],|r| Ok(json!({"seq":r.get::<_,i64>(0)?,"id":r.get::<_,String>(1)?,"text":r.get::<_,String>(2)?,"outgoing":r.get::<_,bool>(3)?,"timestamp":r.get::<_,i64>(4)?,"expires":r.get::<_,Option<i64>>(5)?,"ttl":r.get::<_,Option<u32>>(6)?,"status":r.get::<_,String>(7)?})))?;
                Ok(Value::Array(rows.collect::<rusqlite::Result<Vec<_>>>()?))
            }
            Command::Receive {
                peer,
                alias,
                id,
                text,
                ttl,
                approved,
            } => {
                if let Some(receipt) = self.receipt(&peer, &id, now)? {
                    return Ok(json!(receipt));
                }
                ensure!(
                    approved
                        || self
                            .db
                            .query_row("SELECT trusted FROM peers WHERE peer=?", [&peer], |r| r
                                .get::<_, bool>(0))
                            .optional()?
                            .unwrap_or(false),
                    "Chat consent required"
                );
                validate(&id, &text, ttl)?;
                let tx = self.db.transaction()?;
                tx.execute("INSERT INTO peers(peer,alias,trusted) VALUES(?,?,1) ON CONFLICT(peer) DO UPDATE SET alias=excluded.alias,trusted=1",params![peer,alias])?;
                tx.execute("INSERT INTO messages(peer,id,outgoing,body,search_text,created,delivered,expires,ttl,status,unread) VALUES(?,?,0,?,?,?,?,?,?,'delivered',1)",params![peer,id,text,text.to_lowercase(),now,now,ttl.map(|ttl|now+ttl as i64*1000),ttl])?;
                tx.commit()?;
                if let Some(ttl) = ttl {
                    self.deadline(&peer, &id, false, ttl as i64 * 1000);
                }
                Ok(json!(self.receipt(&peer, &id, now)?.unwrap()))
            }
            Command::Create {
                peer,
                alias,
                id,
                text,
                ttl,
            } => {
                validate(&id, &text, ttl)?;
                let tx = self.db.transaction()?;
                tx.execute("INSERT INTO peers(peer,alias) VALUES(?,?) ON CONFLICT(peer) DO UPDATE SET alias=excluded.alias",params![peer,alias])?;
                tx.execute("INSERT INTO messages(peer,id,outgoing,body,search_text,created,ttl,status) VALUES(?,?,1,?,?,?,?,'failed')",params![peer,id,text,text.to_lowercase(),now,ttl])?;
                tx.commit()?;
                Ok(json!(null))
            }
            Command::Attempt { peer, id } => {
                let ttl: Option<u32> = self.db.query_row("SELECT ttl FROM messages WHERE peer=? AND id=? AND outgoing=1 AND body IS NOT NULL",params![peer,id],|r|r.get(0))?;
                self.db.execute("UPDATE messages SET status='sending',expires=CASE WHEN delivered IS NULL AND expires IS NULL THEN ? ELSE expires END WHERE peer=? AND id=? AND outgoing=1 AND body IS NOT NULL",params![ttl.map(|ttl|now+ttl as i64*1000),peer,id])?;
                if let Some(ttl) = ttl {
                    self.deadlines
                        .entry((peer, id, true))
                        .or_insert_with(|| Instant::now() + Duration::from_secs(ttl as u64));
                }
                Ok(json!(null))
            }
            Command::Status { peer, id, status } => {
                ensure!(
                    ["failed", "declined", "unconfirmed"].contains(&status.as_str()),
                    "Invalid chat status"
                );
                let changed = self.db.execute("UPDATE messages SET status=?,expires=CASE WHEN ?!='unconfirmed' THEN NULL ELSE expires END WHERE peer=? AND id=? AND outgoing=1 AND body IS NOT NULL AND delivered IS NULL",params![status,status,peer,id])?;
                if changed > 0 && status != "unconfirmed" {
                    self.deadlines.remove(&(peer, id, true));
                }
                Ok(json!(null))
            }
            Command::Receipt { peer, id } => Ok(json!(self.receipt(&peer, &id, now)?)),
            Command::Confirm { peer, id, receipt } => {
                ensure!(
                    receipt.message_id == id
                        && ["delivered", "expired", "deleted"].contains(&receipt.status.as_str()),
                    "Invalid chat receipt"
                );
                let (ttl,old_delivered,old_expires,body): (Option<u32>,Option<i64>,Option<i64>,Option<String>) = self.db.query_row("SELECT ttl,delivered,expires,body FROM messages WHERE peer=? AND id=? AND outgoing=1",params![peer,id],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?)))?;
                ensure!(
                    ttl.is_some() == receipt.remaining_ttl_ms.is_some(),
                    "Invalid receipt expiry"
                );
                let duration = receipt
                    .remaining_ttl_ms
                    .map(|ms| ms.clamp(0, ttl.unwrap_or_default() as i64 * 1000));
                let expires = duration.map(|ms| {
                    if old_delivered.is_some() {
                        old_expires.unwrap_or(now + ms).min(now + ms)
                    } else {
                        now + ms
                    }
                });
                if body.is_some() {
                    let removed = receipt.status != "delivered" || duration == Some(0);
                    self.db.execute("UPDATE messages SET delivered=?,expires=?,status=?,body=CASE WHEN ? THEN NULL ELSE body END,search_text=CASE WHEN ? THEN NULL ELSE search_text END WHERE peer=? AND id=? AND outgoing=1",params![receipt.delivered_at_ms,expires,if duration==Some(0){"expired"}else{&receipt.status},removed,removed,peer,id])?;
                    if duration.is_some() {
                        let previous = self
                            .deadlines
                            .get(&(peer.clone(), id.clone(), true))
                            .copied();
                        self.deadline(&peer, &id, true, expires.unwrap() - now);
                        if old_delivered.is_some()
                            && let Some(previous) = previous
                        {
                            let end = self.deadlines.get_mut(&(peer, id, true)).unwrap();
                            *end = (*end).min(previous);
                        }
                    }
                }
                Ok(json!(null))
            }
            Command::Delete { peer, id } => {
                self.db.execute("UPDATE messages SET body=NULL,search_text=NULL,status='deleted',unread=0 WHERE peer=? AND (? IS NULL OR id=?)",params![peer,id,id])?;
                self.deadlines
                    .retain(|(p, i, _), _| p != &peer || id.as_ref().is_some_and(|id| i != id));
                Ok(json!(null))
            }
            Command::Read { peer } => {
                self.db
                    .execute("UPDATE messages SET unread=0 WHERE peer=?", [peer])?;
                Ok(json!(null))
            }
        }
    }
}
fn validate(id: &str, text: &str, ttl: Option<u32>) -> Result<()> {
    ensure!(
        uuid::Uuid::parse_str(id).is_ok_and(|id| id.get_version_num() == 4),
        "Invalid message ID"
    );
    if text.trim().is_empty()
        || text.len() > MAX_MESSAGE_BYTES
        || ttl.is_some_and(|ttl| !TTL_SECONDS.contains(&ttl))
    {
        bail!("Invalid message or expiry");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn command(store: &ChatStore, value: Value, now: i64) -> Value {
        serde_json::from_str(&store.command_at(&value.to_string(), now).unwrap()).unwrap()
    }
    #[test]
    fn expiry_and_deletion_keep_receipts_without_resurrecting_text() {
        let store = ChatStore::open(":memory:").unwrap();
        let id = uuid::Uuid::new_v4().to_string();
        let now = now_ms();
        let msg = json!({"op":"receive","peer":"A","alias":"Alice","id":id,"text":"secret","ttl":300,"approved":true});
        let first = command(&store, msg.clone(), now);
        assert_eq!(
            command(&store, msg.clone(), now + 1000)["deliveredAtMs"],
            first["deliveredAtMs"]
        );
        command(&store, json!({"op":"purge"}), now + 300001);
        assert_eq!(command(&store, msg, now + 300002)["status"], "expired");
        assert_eq!(
            command(
                &store,
                json!({"op":"messages","peer":"A","before":null,"search":""}),
                now + 300002
            ),
            json!([])
        );
        let db = &store.inner.lock().unwrap().db;
        assert_eq!(
            db.query_row(
                "SELECT body IS NULL AND search_text IS NULL FROM messages",
                [],
                |r| r.get::<_, bool>(0)
            )
            .unwrap(),
            true
        );
    }
    #[test]
    fn consent_identity_search_and_local_delete() {
        let store = ChatStore::open(":memory:").unwrap();
        let now = now_ms();
        let id = uuid::Uuid::new_v4().to_string();
        let msg = json!({"op":"receive","peer":"A","alias":"Alice","id":id,"text":"  ZAŻÓŁĆ\n🦀  ","ttl":null,"approved":false});
        assert!(store.command(&msg.to_string()).is_err());
        let mut accepted = msg;
        accepted["approved"] = json!(true);
        command(&store, accepted.clone(), now);
        assert_eq!(
            command(
                &store,
                json!({"op":"messages","peer":"A","before":null,"search":"zażółć"}),
                now
            )[0]["text"],
            accepted["text"]
        );
        assert!(command(&store, json!({"op":"receipt","peer":"B","id":id}), now).is_null());
        command(&store, json!({"op":"delete","peer":"A","id":id}), now);
        assert_eq!(command(&store, accepted, now + 1)["status"], "deleted");
        command(&store, json!({"op":"trust","peer":"A","value":false}), now);
        assert_eq!(
            command(&store, json!({"op":"trusted","peer":"A"}), now),
            false
        );
    }
    #[test]
    fn monotonic_expiry_survives_a_backwards_wall_clock_and_receipts_do_not_extend_it() {
        let store = ChatStore::open(":memory:").unwrap();
        let now = now_ms();
        let id = uuid::Uuid::new_v4().to_string();
        command(
            &store,
            json!({"op":"receive","peer":"A","alias":"Alice","id":id,"text":"secret","ttl":300,"approved":true}),
            now,
        );
        {
            let mut inner = store.inner.lock().unwrap();
            inner.deadlines.insert(
                ("A".into(), id.clone(), false),
                Instant::now() - Duration::from_secs(1),
            );
        }
        let receipt = command(
            &store,
            json!({"op":"receipt","peer":"A","id":id}),
            now - 60000,
        );
        assert_eq!(receipt["status"], "expired");
        assert_eq!(
            command(
                &store,
                json!({"op":"messages","peer":"A","before":null,"search":"secret"}),
                now - 60000
            ),
            json!([])
        );

        let outgoing = uuid::Uuid::new_v4().to_string();
        command(
            &store,
            json!({"op":"create","peer":"B","alias":"Bob","id":outgoing,"text":"outgoing","ttl":300}),
            now,
        );
        let receipt = json!({"messageId":outgoing,"deliveredAtMs":now,"remainingTtlMs":300000,"status":"delivered"});
        command(
            &store,
            json!({"op":"confirm","peer":"B","id":outgoing,"receipt":receipt}),
            now,
        );
        let deadline = store.inner.lock().unwrap().deadlines[&("B".into(), outgoing.clone(), true)];
        command(
            &store,
            json!({"op":"confirm","peer":"B","id":outgoing,"receipt":receipt}),
            now + 1000,
        );
        assert!(
            store.inner.lock().unwrap().deadlines[&("B".into(), outgoing.clone(), true)]
                <= deadline
        );
        // A later definitive error must not remove an already confirmed expiry.
        command(
            &store,
            json!({"op":"status","peer":"B","id":outgoing,"status":"failed"}),
            now + 2000,
        );
        assert!(
            store
                .inner
                .lock()
                .unwrap()
                .deadlines
                .contains_key(&("B".into(), outgoing, true))
        );
    }
    #[test]
    fn lost_ack_expires_and_late_ack_cannot_restore_body() {
        let store = ChatStore::open(":memory:").unwrap();
        let now = now_ms();
        let id = uuid::Uuid::new_v4().to_string();
        command(
            &store,
            json!({"op":"create","peer":"B","alias":"Bob","id":id,"text":"hello","ttl":300}),
            now,
        );
        command(&store, json!({"op":"attempt","peer":"B","id":id}), now);
        command(
            &store,
            json!({"op":"status","peer":"B","id":id,"status":"unconfirmed"}),
            now,
        );
        command(
            &store,
            json!({"op":"confirm","peer":"B","id":id,"receipt":{"messageId":id,"deliveredAtMs":now,"remainingTtlMs":200000,"status":"delivered"}}),
            now + 300001,
        );
        assert_eq!(
            command(
                &store,
                json!({"op":"messages","peer":"B","before":null,"search":""}),
                now + 300001
            ),
            json!([])
        );
    }
}
