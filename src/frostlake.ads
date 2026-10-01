pragma Ada_2022;

--  An Ada driver for Frostlake, speaking the engine's HTTP protocol against
--  a running DatabaseHttpServer.
--
--     Conn : Frostlake.Connection :=
--       Frostlake.Connect ("frostlake://localhost:18082/MY_DB?schema=PUBLIC");
--     R : constant Frostlake.Result :=
--       Conn.Execute ("SELECT id, name FROM people WHERE id = ?",
--                     (1 => Frostlake.To_Cell (Long_Long_Integer'(1))));
--
--  Parameters are inlined client-side (the protocol has no server-side
--  binding), with the same rules as Frostlake's other drivers.  Result cells
--  are a variant record: BOOLEAN cells arrive as Booleans, DATE as
--  Date_Value, TIMESTAMP* as Timestamp_Value, BINARY as raw bytes.
--  Fixed-point NUMBER keeps its exact digits — as a Long_Long_Integer when
--  it is integral and fits, otherwise as the wire's own digit text — while
--  FLOAT/DOUBLE/REAL become Long_Float.

with Ada.Containers.Vectors;
with Ada.Finalization;
private with Ada.Real_Time;
with Ada.Streams;
with Ada.Strings.Unbounded;

package Frostlake is

   Version : constant String := "0.1.0";

   ---------------------------------------------------------------------
   --  Errors.  Ada has no exception hierarchy, so the kinds every
   --  Frostlake driver distinguishes are sibling exceptions.
   ---------------------------------------------------------------------

   --  The server could not be reached, or the connection failed
   --  mid-statement.
   Connection_Error : exception;

   --  The engine rejected a statement.  The message is the engine's own.
   Query_Error : exception;

   --  The driver was asked for something impossible: a malformed DSN, a
   --  closed connection, a bind value with no SQL equivalent.
   Usage_Error : exception;

   --  The engine no longer holds the connection's session — it expired,
   --  was released, or the server restarted — and what the session held
   --  went with it: an open transaction, or context set up on it (a USE,
   --  SET or ALTER SESSION, a temporary object).  The statement did NOT
   --  run.  The connection stays usable, and its next statement starts a
   --  fresh session on the DSN's scope.  (A lost session that held nothing
   --  a fresh one lacks raises nothing: the statement is sent once more in
   --  a fresh session on the DSN's scope.)
   Session_Lost_Error : exception;

   ---------------------------------------------------------------------
   --  Defaults.
   ---------------------------------------------------------------------

   Default_Port : constant := 18_082;

   --  Long enough for a slow query, short enough that an unreachable host
   --  fails while someone is still watching.
   Default_Open_Timeout : constant Duration := 10.0;
   Default_Read_Timeout : constant Duration := 300.0;

   --  The engine reaps a session after 30 minutes idle.  An engine that
   --  answers newSession refuses the lapsed session instead, which the
   --  driver recovers from where it lands; against one from before the
   --  field, past this limit we have to assume ours is gone, because
   --  nothing in a response says so.
   Default_Session_Idle_Limit : constant Duration := 1800.0;

   --  "Not given" for Connect's optional arguments: an explicit argument
   --  outranks the DSN, which outranks the default.
   Unset : constant Duration := -1.0;

   --  "Not given" for Execute's Multi_Statement_Count: no count travels
   --  with the request and the session's MULTI_STATEMENT_COUNT decides.
   No_Multi_Statement_Count : constant Integer := -1;

   ---------------------------------------------------------------------
   --  Dates and timestamps.  Deliberately plain records rather than
   --  Ada.Calendar.Time: the engine's range (year 1 .. 9999) exceeds
   --  Ada.Calendar's, and a record keeps the wire's digits exact.
   ---------------------------------------------------------------------

   type Date_Value is record
      Year  : Integer range 1 .. 9999 := 1;
      Month : Integer range 1 .. 12 := 1;
      Day   : Integer range 1 .. 31 := 1;
   end record;

   type Timestamp_Value is record
      Year       : Integer range 1 .. 9999 := 1;
      Month      : Integer range 1 .. 12 := 1;
      Day        : Integer range 1 .. 31 := 1;
      Hour       : Integer range 0 .. 23 := 0;
      Minute     : Integer range 0 .. 59 := 0;
      Second     : Integer range 0 .. 59 := 0;
      Nanosecond : Integer range 0 .. 999_999_999 := 0;
      --  TIMESTAMP_TZ / TIMESTAMP_LTZ carry an offset; TIMESTAMP_NTZ does
      --  not.  Offset_Minutes is positive east of UTC.
      Has_Offset     : Boolean := False;
      Offset_Minutes : Integer range -1080 .. 1080 := 0;
   end record;

   function Image (Value : Date_Value) return String;
   --  "YYYY-MM-DD".

   function Image (Value : Timestamp_Value) return String;
   --  "YYYY-MM-DD HH:MM:SS.NNNNNNNNN" plus " +HHMM" when an offset is
   --  carried.

   ---------------------------------------------------------------------
   --  Cells.  One value of a result set — and equally one bind value:
   --  what Execute hands back can be bound straight into the next
   --  statement.
   ---------------------------------------------------------------------

   type Cell_Kind is
     (Null_Kind,
      Boolean_Kind,
      Integer_Kind,      --  integral numeric that fits Long_Long_Integer
      Decimal_Kind,      --  exact fixed-point digits, kept as text
      Float_Kind,        --  FLOAT / DOUBLE / REAL: genuine binary floats
      Text_Kind,         --  VARCHAR and anything else textual (incl. TIME)
      Date_Kind,
      Timestamp_Kind,
      Binary_Kind,       --  raw bytes
      Variant_Kind);     --  VARIANT / OBJECT / ARRAY: the cell's JSON text

   type Cell (Kind : Cell_Kind := Null_Kind) is record
      case Kind is
         when Null_Kind =>
            null;
         when Boolean_Kind =>
            Bool : Boolean := False;
         when Integer_Kind =>
            Int : Long_Long_Integer := 0;
         when Decimal_Kind =>
            Exact : Ada.Strings.Unbounded.Unbounded_String;
         when Float_Kind =>
            Real : Long_Float := 0.0;
         when Text_Kind =>
            Text : Ada.Strings.Unbounded.Unbounded_String;
         when Date_Kind =>
            Date : Date_Value;
         when Timestamp_Kind =>
            Stamp : Timestamp_Value;
         when Binary_Kind =>
            --  One Character per byte; As_Binary re-types it.
            Bytes : Ada.Strings.Unbounded.Unbounded_String;
         when Variant_Kind =>
            Json : Ada.Strings.Unbounded.Unbounded_String;
      end case;
   end record;

   --  Constructors.

   function Null_Cell return Cell;
   function To_Cell (Value : Boolean) return Cell;
   function To_Cell (Value : Long_Long_Integer) return Cell;
   function To_Cell (Value : Long_Float) return Cell;
   function To_Cell (Value : String) return Cell;
   function To_Cell (Value : Date_Value) return Cell;
   function To_Cell (Value : Timestamp_Value) return Cell;
   function To_Binary (Value : Ada.Streams.Stream_Element_Array) return Cell;
   function To_Decimal (Exact_Digits : String) return Cell;
   --  Exact_Digits must be a plain SQL numeric literal (optional sign,
   --  digits, optional fraction, optional exponent); anything else raises
   --  Usage_Error — the text is later inlined into SQL verbatim.
   function To_Variant (Json_Text : String) return Cell;
   --  Bound as PARSE_JSON('<text>').

   --  Accessors.  A kind mismatch raises Usage_Error; the numeric ones
   --  convert between numeric kinds where that is lossless (or, for
   --  As_Float, merely honest).

   function Is_Null (Value : Cell) return Boolean;
   function As_Boolean (Value : Cell) return Boolean;
   function As_Integer (Value : Cell) return Long_Long_Integer;
   --  Integer_Kind, or a Decimal_Kind whose digits are integral.
   function As_Float (Value : Cell) return Long_Float;
   --  Any numeric kind.
   function As_String (Value : Cell) return String;
   --  Text_Kind, Variant_Kind, or a Decimal_Kind's digit text.
   function As_Date (Value : Cell) return Date_Value;
   function As_Timestamp (Value : Cell) return Timestamp_Value;
   function As_Binary (Value : Cell) return Ada.Streams.Stream_Element_Array;

   function Image (Value : Cell) return String;
   --  A readable rendering of any kind — for logs and tests, not for SQL.

   ---------------------------------------------------------------------
   --  Binds.
   ---------------------------------------------------------------------

   type Bind_Array is array (Positive range <>) of Cell;

   No_Binds : constant Bind_Array (1 .. 0) := [];

   ---------------------------------------------------------------------
   --  Results.
   ---------------------------------------------------------------------

   type Nullability is (Unknown, Nullable, Not_Nullable);

   type Column_Info is record
      Name      : Ada.Strings.Unbounded.Unbounded_String;
      Data_Type : Ada.Strings.Unbounded.Unbounded_String;
      Precision : Natural := 0;
      Scale     : Natural := 0;
      --  The declared width of a text (characters) or binary (bytes)
      --  column -- the type's maximum when the column is unbounded.  The
      --  account reports this one number as both the column's precision
      --  and its display size.  Has_Length is False for every other type,
      --  and for a server that predates the field: the width is unknown,
      --  not zero.
      Has_Length : Boolean := False;
      Length     : Natural := 0;
      --  Whether the column is KNOWN to accept NULL; Unknown means the
      --  server predates the field.
      Can_Be_Null : Nullability := Unknown;
   end record;

   package Column_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Column_Info);

   package Cell_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Cell);

   package Row_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Cell_Vectors.Vector,
      "="          => Cell_Vectors."=");

   --  Rows and cells are indexed from 1.  Row_Count is the number of rows
   --  for a query, and the affected-row count for DML (whose status row is
   --  absorbed: Columns and Rows are then empty).
   type Result is record
      Columns   : Column_Vectors.Vector;
      Rows      : Row_Vectors.Vector;
      Row_Count : Natural := 0;
   end record;

   package Result_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Result);

   function Column_Count (From : Result) return Natural;
   function Column_Name (From : Result; Index : Positive) return String;
   function Column_Index (From : Result; Name : String) return Natural;
   --  The first column matching Name — exactly, else case-insensitively —
   --  or 0 when there is none.
   function Value (From : Result; Row : Positive; Col : Positive)
      return Cell;
   function Value (From : Result; Row : Positive; Name : String)
      return Cell;
   --  Raises Usage_Error when no column matches Name.

   ---------------------------------------------------------------------
   --  Connections.
   ---------------------------------------------------------------------

   type Connection is tagged limited private;

   function Connect
     (Dsn                : String;
      Open_Timeout       : Duration := Unset;
      Read_Timeout       : Duration := Unset;
      Session_Idle_Limit : Duration := Unset) return Connection;
   --  Connects, verifies the server is reachable via GET /api/health, and
   --  applies the database and schema from the DSN.  The DSN is
   --  frostlake://host[:port][/database][?schema=...] (http:// works too;
   --  https is not supported by this driver).  The query string may also
   --  carry open_timeout, read_timeout and session_idle_limit, in seconds;
   --  an explicit argument outranks them.  A Session_Idle_Limit of 0.0
   --  switches the idle-session check off.

   procedure Ping (Conn : in out Connection);
   --  Raises Connection_Error unless GET /api/health answers 2xx.

   function Execute
     (Conn                  : in out Connection;
      Sql                   : String;
      Binds                 : Bind_Array := No_Binds;
      Multi_Statement_Count : Integer := No_Multi_Statement_Count)
      return Result;
   --  Executes one statement.  A multi-statement string answers with its
   --  first result set — use Execute_All for the rest.

   function Execute_All
     (Conn                  : in out Connection;
      Sql                   : String;
      Binds                 : Bind_Array := No_Binds;
      Multi_Statement_Count : Integer := No_Multi_Statement_Count)
      return Result_Vectors.Vector;
   --  Every result set the statement string produced, in order.
   --
   --  Multi_Statement_Count says how many statements this call carries, 0
   --  for any number; the engine refuses a call whose count differs, as
   --  the account does.  It travels with this one request and outranks the
   --  session's MULTI_STATEMENT_COUNT for it without changing any session
   --  state, so there is nothing to put back afterwards and another task
   --  sharing the connection is unaffected.  Left at
   --  No_Multi_Statement_Count nothing is sent and the session decides.

   procedure Execute
     (Conn                  : in out Connection;
      Sql                   : String;
      Binds                 : Bind_Array := No_Binds;
      Multi_Statement_Count : Integer := No_Multi_Statement_Count);
   --  Execute, discarding the result — for DDL and fire-and-forget DML.

   procedure Begin_Transaction (Conn : in out Connection);
   procedure Commit (Conn : in out Connection);
   procedure Rollback (Conn : in out Connection);

   generic
      with procedure Work (Conn : in out Connection);
   procedure Run_In_Transaction (Conn : in out Connection);
   --  BEGIN, Work, COMMIT — rolling back on any exception and re-raising
   --  it (a failed rollback never replaces the exception that caused it).

   function In_Transaction (Conn : Connection) return Boolean;
   --  Whether a transaction is open on the session: from Begin_Transaction,
   --  or a BEGIN or START TRANSACTION sent as a statement, until its COMMIT
   --  or ROLLBACK.

   function Session (Conn : Connection) return String;
   --  The engine's id for the connection's session, or "" before the
   --  first statement, after a lost session was dropped, and once closed.

   procedure Close (Conn : in out Connection);
   function Is_Closed (Conn : Connection) return Boolean;
   --  Closing is idempotent; every other operation on a closed connection
   --  raises Usage_Error.  A Connection also closes itself when it goes
   --  out of scope.  Closing gives the engine its session back with
   --  DELETE /api/sessions/{id}, which also rolls back a transaction left
   --  open on it — best effort: it waits no longer than five seconds (or
   --  the connection's own shorter timeouts), never raises, and only the
   --  first close sends it.  An engine that answers no newSession has no
   --  such endpoint and is sent nothing; its session lingers until the
   --  engine's idle expiry.

   function Last_Error_Message (Conn : Connection) return String;
   --  The engine's message from the most recent Query_Error, in full.
   --  GNAT truncates exception messages around 200 characters, and the
   --  engine's compilation errors can run far longer — this keeps every
   --  character.

private

   package String_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Ada.Strings.Unbounded.Unbounded_String,
      "="          => Ada.Strings.Unbounded."=");

   --  What the engine is known to do with the session id a request names.
   --  An engine that answers newSession (Tracked) also honours
   --  requireSession and DELETE /api/sessions/{id}; one from before the
   --  field (Untracked) knows neither, and its parser may refuse a field it
   --  does not know.
   type Session_Support is (Unknown, Tracked, Untracked);

   --  One statement at a time per connection: statements serialize so a
   --  Connection can be shared between tasks without interleaving them —
   --  the lock is held across the USE replay and the statement itself.
   protected type Mutex_Type is
      entry Seize;
      procedure Release;
   private
      Held : Boolean := False;
   end Mutex_Type;

   type Connection is new Ada.Finalization.Limited_Controlled with record
      Lock : Mutex_Type;

      Host : Ada.Strings.Unbounded.Unbounded_String;
      Port : Positive := Default_Port;

      Open_Timeout : Duration := Default_Open_Timeout;
      Read_Timeout : Duration := Default_Read_Timeout;
      Idle_Limit   : Duration := Default_Session_Idle_Limit;

      Session_Id  : Ada.Strings.Unbounded.Unbounded_String;
      Auto_Commit : Boolean := True;
      Closed      : Boolean := False;

      --  Whether the engine keeps sessions to their id.  Unknown until the
      --  first answer that names a session.
      Sessions : Session_Support := Unknown;
      --  A transaction is open: from BEGIN (however it was sent) until
      --  COMMIT or ROLLBACK.
      Transaction_Open : Boolean := False;

      --  Whether a statement has left state behind that a fresh session
      --  would not have — a scope the caller selected themselves, a
      --  variable, a setting, a temporary object.  Once it has, the DSN's
      --  defaults are no longer the whole truth about this session.
      Session_Touched : Boolean := False;
      Has_Last_Used   : Boolean := False;
      Last_Used_At    : Ada.Real_Time.Time := Ada.Real_Time.Time_First;

      Pending_Use      : String_Vectors.Vector;
      --  Kept so they can be put back if the session is replaced under us.
      Session_Defaults : String_Vectors.Vector;

      Last_Error : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   overriding procedure Finalize (Conn : in out Connection);

end Frostlake;
