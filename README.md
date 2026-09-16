# frostlake-ada

A dependency-free Ada driver for [Frostlake](https://frostlake.dev), speaking the
engine's HTTP protocol against a running `DatabaseHttpServer`. Ada 2022, GNAT's
own runtime only — the HTTP client is `GNAT.Sockets`, the JSON layer is the
driver's own — packaged as an [Alire](https://alire.ada.dev) crate.

## Building

```sh
alr build                 # the library
cd tests && alr build     # the test suite (pins the library via path)
```

To use it from another crate before it is published, pin it by path:

```toml
[[depends-on]]
frostlake = "*"

[[pins]]
frostlake = { path = "../frostlake-ada" }
```

## Engine version

Requires a Frostlake engine **0.0.7 or newer**. Ask a running server which one it
is with `SELECT CURRENT_VERSION()`. The driver versions independently of the
engine: it speaks the HTTP protocol, not the jar, so this is a floor rather than
a lockstep pin.

Two behaviours depend on the engine version. A `TIMESTAMP_TZ` column only reports
back the UTC offset it was given from engine **0.1.0** on — against an older
engine a bound timestamp still round-trips, but the offset comes back as `+0000`.
And column nullability (`Column_Info.Can_Be_Null`) reads `Unknown` from servers
that predate the field, as does a text or binary column's declared width
(`Column_Info.Has_Length` / `.Length` — characters for text, bytes for binary;
`Has_Length` is False for every other type).

## Usage

```ada
with Ada.Text_IO;
with Frostlake; use Frostlake;

procedure Demo is
   Conn : Connection :=
     Connect ("frostlake://localhost:18082/MY_DB?schema=PUBLIC");
begin
   Conn.Execute ("CREATE TABLE PEOPLE (ID INTEGER, NAME VARCHAR)");

   declare
      R : constant Result := Conn.Execute
        ("INSERT INTO PEOPLE VALUES (?, ?), (?, ?)",
         [To_Cell (Long_Long_Integer'(1)), To_Cell ("Ada"),
          To_Cell (Long_Long_Integer'(2)), To_Cell ("Grace")]);
   begin
      Ada.Text_IO.Put_Line (R.Row_Count'Image);  --  2
   end;

   declare
      R : constant Result := Conn.Execute
        ("SELECT ID, NAME FROM PEOPLE WHERE ID = ?",
         [To_Cell (Long_Long_Integer'(1))]);
   begin
      Ada.Text_IO.Put_Line (As_String (Value (R, 1, "NAME")));  --  Ada
   end;

   Conn.Close;
end Demo;
```

`Execute (Conn, Sql, Binds)` exists three ways: a function returning the first
`Result`, a function `Execute_All` returning every result set a multi-statement
string produced, and a procedure that discards the result for DDL. A string
holding more than one statement has to be asked for first — `ALTER SESSION SET
MULTI_STATEMENT_COUNT = n` for exactly `n`, or `0` for any number; a session at
the default of one refuses a request that carries more. Parameters
are inlined client-side (the protocol has no server-side binding): each `?`
outside string literals, quoted identifiers, comments and `$$…$$` bodies is
replaced by the next bind's SQL literal.

A call can declare its own count instead of asking the session, with the
optional `Multi_Statement_Count` argument all three Execute forms take:

```ada
   All_Sets : constant Result_Vectors.Vector :=
     Conn.Execute_All ("SELECT 1 AS A; SELECT 2 AS B",
                       Multi_Statement_Count => 2);
```

It says how many statements that one call carries, `0` for any number. The count
travels with that request and outranks the session's `MULTI_STATEMENT_COUNT` for
it, but changes no session state — nothing to put back afterwards, and another
task sharing the connection is unaffected. Left at its default,
`No_Multi_Statement_Count`, nothing is sent and the session's value decides,
which is one statement until it is told otherwise.

A `Result` carries `Columns`, `Rows` (vectors of cells, indexed from 1) and
`Row_Count` — the affected-row count for DML, whose status row is absorbed.
`Value (R, Row, "NAME")` looks a cell up by column name (exact first, then
case-insensitively); `Value (R, Row, Col)` by position.

### Cells

A cell is a variant record — the same type serves results and binds, so what a
query hands back can be bound straight into the next statement:

| engine type                      | `Cell.Kind`      | accessor |
| -------------------------------- | ---------------- | -------- |
| `NULL`                           | `Null_Kind`      | `Is_Null` |
| `BOOLEAN`                        | `Boolean_Kind`   | `As_Boolean` |
| fixed-point that fits 64 bits    | `Integer_Kind`   | `As_Integer` |
| any other fixed-point `NUMBER`   | `Decimal_Kind`   | `As_String` (exact digits), `As_Float` |
| `FLOAT` / `DOUBLE` / `REAL`      | `Float_Kind`     | `As_Float` |
| `VARCHAR`, `TIME`, anything else | `Text_Kind`      | `As_String` |
| `DATE`                           | `Date_Kind`      | `As_Date` |
| `TIMESTAMP*` / `DATETIME`        | `Timestamp_Kind` | `As_Timestamp` |
| `BINARY`                         | `Binary_Kind`    | `As_Binary` |
| `VARIANT` / `OBJECT` / `ARRAY`   | `Variant_Kind`   | `As_String` (the JSON text) |

Fixed-point `NUMBER` keeps its exact digits: integral values that fit become
`Long_Long_Integer`, everything else keeps the wire's digit text unrounded
(`To_Decimal ("12.34")` binds one back). Timestamps and dates are plain records
(`Timestamp_Value`, `Date_Value`) rather than `Ada.Calendar.Time`, because the
engine's range and nanosecond precision exceed it; a bound timestamp carrying an
offset maps to `TIMESTAMP_TZ`, an offset-less one to `TIMESTAMP_NTZ`. A
`To_Variant` bind arrives as `PARSE_JSON('…')`.

### Errors

Every failure is one of three exceptions: `Connection_Error` (server unreachable
or failed mid-statement), `Query_Error` (the engine rejected a statement — the
message is the engine's own), `Usage_Error` (driver misuse: malformed DSN, closed
connection, bad bind). GNAT truncates exception messages around 200 characters
and engine compilation errors can run far longer, so the full text of the most
recent `Query_Error` is also kept on the connection: `Last_Error_Message (Conn)`.

### Transactions

```ada
Conn.Begin_Transaction;
Conn.Execute ("INSERT INTO PEOPLE VALUES (3, 'Edsger')");
Conn.Commit;   --  or Conn.Rollback;
```

or generically — `Run_In_Transaction` commits on return, rolls back and
re-raises on any exception:

```ada
procedure Work (C : in out Connection) is ...;
procedure Tx is new Frostlake.Run_In_Transaction (Work);
...
Tx (Conn);
```

## DSN

`frostlake://host[:port][/database][?parameters]` — `http://` works too. The
default port is 18082. The database and schema named in the DSN are applied by
`Connect`, so a name that does not exist is reported there rather than surfacing
later on whatever query happens to run first; both are quoted before they are
sent. Query parameters (an explicit `Connect` argument outranks them):

| parameter            | default | meaning |
| -------------------- | ------- | ------- |
| `schema`             | —       | `USE SCHEMA` after connecting |
| `open_timeout`       | 10      | seconds to establish a connection |
| `read_timeout`       | 300     | seconds to wait for a response |
| `session_idle_limit` | 1800    | see below; `0` switches the check off |

The engine reaps a session after 30 minutes idle and then quietly builds a fresh
one for the id the driver keeps sending, losing the database and schema it
selected — nothing in a response says so. Past `session_idle_limit` the driver
therefore re-applies the DSN's `USE` statements, unless the caller has run a
`USE` of their own.

`https` DSNs are not supported (`GNAT.Sockets` has no TLS; the engine speaks
plain HTTP), which is this driver's one deliberate divergence from its siblings.

## Concurrency

A `Connection` can be shared between tasks: statements serialize on an internal
lock, one at a time per connection, exactly as the engine's session expects.
Each request opens a fresh connection and sends `Connection: close` — measured
against `DatabaseHttpServer`, that is *faster* than keep-alive (a reused
connection hits a delayed-ACK stall of ~48 ms per statement versus ~0.8 ms for a
fresh one), so do not "optimise" it away.

## Tests

```sh
cd tests
alr build
./bin/frostlake_tests
```

The unit half — the wire pieces directly, plus the whole driver against a
loopback HTTP server — always runs and needs no JVM. The integration half boots
a real `DatabaseHttpServer` and self-skips unless `FROSTLAKE_CLASSPATH` is set
to a classpath containing the engine jar and its runtime dependencies (Jackson 3
core/databind + the Jackson 2 annotations jar, the ANTLR 4 runtime, SLF4J api +
simple, aircompressor, JLine, GraalVM polyglot). With Maven available, a
throwaway pom depending on `dev.frostlake:frostlake-db` and
`mvn -o dependency:build-classpath` produces it. `java` must be a JDK 17 or
newer (`JAVA_HOME` is honoured).

## License

Apache-2.0 — see `LICENSE`.
