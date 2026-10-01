--  Replays the engine-owned testkit corpus through THIS driver.
--
--  The corpus is the language-neutral JSON suites of the frostlake repo
--  (engine/src/test/resources/testkit/suites/*.json, the format in SCHEMA.md
--  beside them): statements, the values they must answer, the refusals they
--  must draw.  This program is only the Ada runner, a port of the Java
--  reference runner (engine/src/test/java/dev/frostlake/testkit), so suites
--  added on the engine side are picked up with no change here.  From the
--  checkout root:
--
--     FL_CORPUS=/path/to/frostlake/engine/src/test/resources/testkit \
--       FROSTLAKE_URL=frostlake://127.0.0.1:18082 tests/bin/testkit_runner
--
--  The driver's own suite, tests/bin/frostlake_tests, runs it the same way
--  when FL_CORPUS is set.
--
--  Environment:
--     FL_CORPUS                 the testkit directory to replay, its suites
--                               in suites/*.json; unset, nothing is run
--     FROSTLAKE_URL             the running DatabaseHttpServer to attach to
--     FROSTLAKE_TESTKIT_REPORT  the TSV report; results/testkit-ada.tsv by
--                               default, with missing-apis-ada.md beside it
--     FROSTLAKE_TESTKIT_FILTER  run only the suite files whose name holds
--                               this text
--
--  Semantics, as SCHEMA.md and the reference have them:
--   - a case is skipped when its skip clause names `ada`, or `http`: this
--     driver speaks the HTTP protocol, so what that transport cannot express
--     is out of reach here too;
--   - every case runs on a connection of its own, opened with Connect and
--     released with Close, and starts from the reset sequence below; its
--     steps then run in order on that one session, which is what carries
--     USE, variables and transactions from step to step;
--   - the first failed check stops the case; a refusal is a result, but a
--     transport failure is an ERROR and satisfies no expectation;
--   - capabilities: SESSION, COLUMN_NAMES and UPDATE_COUNT, which is the
--     driver's own affected-row count: it folds a DML statement's count grid
--     into that number.  There is no ERROR_CODE: a refusal carries a message
--     only, so an expected error's code or SQLSTATE is recorded in
--     missing-apis-ada.md rather than failed;
--   - values compare after the reference's normalization (Testkit_Values),
--     each cell read as the text the wire carried for it.
--
--  The last line printed is the tally; the exit status is 1 when any case
--  failed or errored, 2 when there was nothing to run against — FL_CORPUS
--  holding no suites, or no server — and 0 when FL_CORPUS is unset.

with Ada.Command_Line;
with Ada.Containers.Vectors;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with Frostlake;
with Testkit_Json;
with Testkit_Values;

procedure Testkit_Runner is

   use Ada.Strings.Unbounded;
   use Testkit_Json;
   use Testkit_Values;

   --  The names a skip clause can use for this runner.
   Backend_Name   : constant String := "ada";
   Transport_Name : constant String := "http";

   Default_Report : constant String := "results/testkit-ada.tsv";

   --  Every case starts here: a session that takes a script of any length —
   --  several steps send two or three statements at once — and an empty
   --  test_db.test_schema, made current.
   Reset_Context : constant array (1 .. 5) of Unbounded_String :=
     [To_Unbounded_String ("ALTER SESSION SET MULTI_STATEMENT_COUNT = 0"),
      To_Unbounded_String ("CREATE OR REPLACE DATABASE test_db"),
      To_Unbounded_String ("USE DATABASE test_db"),
      To_Unbounded_String ("CREATE OR REPLACE SCHEMA test_schema"),
      To_Unbounded_String ("USE SCHEMA test_schema")];

   Error_Code_Check : constant String :=
     "ERROR_CODE: cannot check error code/sqlState"
     & " (backend reports message only)";

   --  Failures echoed to the console as they happen; the report has all.
   Max_Echoed : constant := 50;

   --  A failure's detail beyond this is cut: a mismatched grid can be large.
   Max_Detail : constant := 8_000;

   Tab : constant Character := Character'Val (9);
   Unit_Separator : constant Character := Character'Val (16#1F#);

   package Name_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Unbounded_String);

   package Name_Sorting is new Name_Vectors.Generic_Sorting;

   package Cell_Rows is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Text_Cell);

   package Grids is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Cell_Rows.Vector,
      "="          => Cell_Rows."=");

   --  One statement's outcome, in the reference's shape: the first result
   --  set as text, its DML count (-1 when there is none), or the refusal.
   type Statement_Outcome is record
      Refused      : Boolean := False;
      Message      : Unbounded_String;
      Columns      : Name_Vectors.Vector;
      Rows         : Grids.Vector;
      Update_Count : Long_Long_Integer := -1;
   end record;

   type Case_Status is (Pass, Fail, Error, Skip);

   function Status_Name (Status : Case_Status) return String is
     (case Status is
         when Pass  => "PASS",
         when Fail  => "FAIL",
         when Error => "ERROR",
         when Skip  => "SKIP");

   --  A check the transport could not express, and where it was asked for.
   type Missing_Check is record
      Check : Unbounded_String;
      Where : Unbounded_String;
   end record;

   package Missing_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Missing_Check);

   Url         : Unbounded_String;
   Report_File : Ada.Text_IO.File_Type;
   Missing     : Missing_Vectors.Vector;

   Passed  : Natural := 0;
   Failed  : Natural := 0;
   Errored : Natural := 0;
   Skipped : Natural := 0;
   Echoed  : Natural := 0;

   ------------------------
   --  Small helpers     --
   ------------------------

   function Img (Value : Long_Long_Integer) return String is
     (Ada.Strings.Fixed.Trim (Long_Long_Integer'Image (Value),
                              Ada.Strings.Left));

   function Describe (E : Ada.Exceptions.Exception_Occurrence)
      return String is
     (Ada.Exceptions.Exception_Name (E) & ": "
      & Ada.Exceptions.Exception_Message (E));

   --  A report field: a tab or a line break would split the row.
   function Clean (Text : String) return String is
      Result : String := Text;
   begin
      for C of Result loop
         if C < ' ' then
            C := ' ';
         end if;
      end loop;
      return Result;
   end Clean;

   function Capped (Text : String) return String is
   begin
      if Text'Length <= Max_Detail then
         return Text;
      end if;
      return Text (Text'First .. Text'First + Max_Detail - 1)
        & " ... (" & Img (Long_Long_Integer (Text'Length))
        & " characters)";
   end Capped;

   --  The directory part of a path, "" for a bare file name.
   function Directory_Of (Path : String) return String is
   begin
      for I in reverse Path'Range loop
         if Path (I) = '/' then
            return (if I = Path'First then "/"
                    else Path (Path'First .. I - 1));
         end if;
      end loop;
      return "";
   end Directory_Of;

   --  Whether Path is a directory with a suite file in it.
   function Holds_Suites (Path : String) return Boolean is
      use Ada.Directories;
      Search : Search_Type;
      Found  : Boolean;
   begin
      if not Exists (Path) or else Kind (Path) /= Directory then
         return False;
      end if;
      Start_Search (Search, Path, "*.json",
                    [Ordinary_File => True, others => False]);
      Found := More_Entries (Search);
      End_Search (Search);
      return Found;
   exception
      when Name_Error | Use_Error =>
         return False;
   end Holds_Suites;

   function Read_File (Path : String) return String is
      use Ada.Streams.Stream_IO;
      File : File_Type;
   begin
      Open (File, In_File, Path);
      declare
         Content : String (1 .. Natural (Size (File)));
      begin
         String'Read (Stream (File), Content);
         Close (File);
         return Content;
      end;
   exception
      when others =>
         if Is_Open (File) then
            Close (File);
         end if;
         raise;
   end Read_File;

   --  Java's List.toString, for a grid or a name list in a message.
   function Listed (Items : Name_Vectors.Vector) return String is
      Out_Text : Unbounded_String := To_Unbounded_String ("[");
   begin
      for I in 1 .. Items.Last_Index loop
         if I > 1 then
            Append (Out_Text, ", ");
         end if;
         Append (Out_Text, Items (I));
      end loop;
      Append (Out_Text, "]");
      return To_String (Out_Text);
   end Listed;

   ------------------------
   --  Expected values   --
   ------------------------

   --  An expected value as the reference reads it, String.valueOf of the
   --  parsed JSON: a number as BigDecimal prints it plainly, and an array
   --  or an object in Java's collection form, [a, b] and {k=v}.
   function Java_Text (Doc : Document; Item : Node) return String is
      Out_Text : Unbounded_String;
   begin
      case Kind (Doc, Item) is
         when Null_Value =>
            return "null";
         when Number_Value =>
            return Plain_Number (Text (Doc, Item));
         when Boolean_Value | String_Value =>
            return Text (Doc, Item);
         when Array_Value | Object_Value =>
            for I in 1 .. Length (Doc, Item) loop
               if I > 1 then
                  Append (Out_Text, ", ");
               end if;
               if Kind (Doc, Item) = Object_Value then
                  Append (Out_Text, Key (Doc, Element (Doc, Item, I)) & "=");
               end if;
               Append (Out_Text, Java_Text (Doc, Element (Doc, Item, I)));
            end loop;
            return (if Kind (Doc, Item) = Array_Value
                    then "[" & To_String (Out_Text) & "]"
                    else "{" & To_String (Out_Text) & "}");
      end case;
   end Java_Text;

   --  An expected cell: its Java_Text, or SQL NULL.
   function Expected_Cell (Doc : Document; Item : Node) return Text_Cell is
   begin
      if Kind (Doc, Item) = Null_Value then
         return Null_Text;
      end if;
      return To_Text_Cell (Java_Text (Doc, Item));
   end Expected_Cell;

   --  A number field (rowCount, updateCount) as an integer, the way
   --  BigDecimal.intValue reads it; Ok is False for anything else.
   procedure Integer_Field
     (Doc   : Document;
      Item  : Node;
      Value : out Long_Long_Integer;
      Ok    : out Boolean) is
   begin
      Value := 0;
      Ok := False;
      if Kind (Doc, Item) /= Number_Value then
         return;
      end if;
      declare
         Plain : constant String := Plain_Number (Text (Doc, Item));
         Point : constant Natural := Ada.Strings.Fixed.Index (Plain, ".");
         Whole : constant String :=
           (if Point = 0 then Plain else Plain (Plain'First .. Point - 1));
      begin
         Value := Long_Long_Integer'Value (Whole);
         Ok := True;
      exception
         when Constraint_Error =>
            null;
      end;
   end Integer_Field;

   ------------------------
   --  One statement     --
   ------------------------

   --  Runs Sql on the case's session.  A refusal comes back in the outcome;
   --  a transport failure propagates.
   function Run_Statement
     (Conn : in out Frostlake.Connection;
      Sql  : String) return Statement_Outcome
   is
      Outcome : Statement_Outcome;
   begin
      declare
         Set : constant Frostlake.Result := Conn.Execute (Sql);
      begin
         for Column of Set.Columns loop
            Outcome.Columns.Append (Column.Name);
         end loop;
         for Row_Index in 1 .. Set.Rows.Last_Index loop
            declare
               Cells : Cell_Rows.Vector;
            begin
               for Col in 1 .. Set.Rows (Row_Index).Last_Index loop
                  declare
                     Cell : constant Text_Cell :=
                       Cell_Text (Frostlake.Value (Set, Row_Index, Col));
                  begin
                     if Col <= Set.Columns.Last_Index
                       and then Is_Semi_Structured
                                  (To_String (Set.Columns (Col).Data_Type))
                     then
                        Cells.Append (Semi_Structured_Value (Cell));
                     else
                        Cells.Append (Cell);
                     end if;
                  end;
               end loop;
               Outcome.Rows.Append (Cells);
            end;
         end loop;

         if Set.Columns.Is_Empty then
            --  The driver folds a DML statement's count grid into its
            --  affected-row count, and the grid's columns go with it.
            Outcome.Update_Count := Long_Long_Integer (Set.Row_Count);
         elsif Natural (Outcome.Rows.Length) = 1
           and then not Outcome.Rows (1).Is_Empty
         then
            --  The reference's derivation for a grid that reached us: one
            --  row whose columns are all "number of ...".
            declare
               All_Counts : Boolean := True;
            begin
               for Name of Outcome.Columns loop
                  declare
                     Folded : constant String := Lower (To_String (Name));
                  begin
                     if Folded'Length < 9
                       or else Folded (Folded'First .. Folded'First + 8)
                                 /= "number of"
                     then
                        All_Counts := False;
                     end if;
                  end;
               end loop;
               if All_Counts and then Outcome.Rows (1) (1).Present then
                  Outcome.Update_Count :=
                    Long_Long_Integer'Value
                      (To_String (Outcome.Rows (1) (1).Text));
               end if;
            exception
               when Constraint_Error =>
                  --  Named like a count but holding something else.
                  null;
            end;
         end if;
      end;
      return Outcome;
   exception
      when Frostlake.Query_Error =>
         --  The exception's own message is cut at GNAT's limit; the
         --  connection keeps the whole of it.
         Outcome := (Refused => True,
                     Message => To_Unbounded_String
                                  (Conn.Last_Error_Message),
                     others  => <>);
         return Outcome;
   end Run_Statement;

   ------------------------
   --  Checks            --
   ------------------------

   function First_Cell (Outcome : Statement_Outcome) return Text_Cell is
   begin
      if Outcome.Rows.Is_Empty or else Outcome.Rows (1).Is_Empty then
         return Null_Text;
      end if;
      return Outcome.Rows (1) (1);
   end First_Cell;

   --  Each row as one string of normalized cells, in the given order or
   --  sorted, so two grids compare as lists (or as bags of rows).
   function Canonical (Grid : Grids.Vector; Ordered : Boolean)
      return Name_Vectors.Vector
   is
      Lines : Name_Vectors.Vector;
   begin
      for Row of Grid loop
         declare
            Line : Unbounded_String;
         begin
            for Cell of Row loop
               Append (Line, Norm (Cell));
               Append (Line, Unit_Separator);
            end loop;
            Lines.Append (Line);
         end;
      end loop;
      if not Ordered then
         Name_Sorting.Sort (Lines);
      end if;
      return Lines;
   end Canonical;

   --  A canonical grid for a message, its cells split by " | ".
   function Shown (Lines : Name_Vectors.Vector) return String is
      Readable : Name_Vectors.Vector;
   begin
      for Line of Lines loop
         declare
            Text_Of : constant String := To_String (Line);
            Out_Text : Unbounded_String;
         begin
            for I in Text_Of'Range loop
               if Text_Of (I) = Unit_Separator then
                  if I < Text_Of'Last then
                     Append (Out_Text, " | ");
                  end if;
               else
                  Append (Out_Text, Text_Of (I));
               end if;
            end loop;
            Readable.Append (Out_Text);
         end;
      end loop;
      return Listed (Readable);
   end Shown;

   --  The statement was EXPECTED to fail: check it did, with the named
   --  message.  A code or SQLSTATE needs ERROR_CODE, which HTTP lacks.
   procedure Check_Refusal
     (Doc     : Document;
      Wanted  : Node;
      Outcome : Statement_Outcome;
      Where   : String;
      Ok      : out Boolean;
      Detail  : out Unbounded_String) is
   begin
      Ok := False;
      Detail := Null_Unbounded_String;
      if not Outcome.Refused then
         Detail := To_Unbounded_String
           ("expected an error, statement succeeded");
         return;
      end if;
      declare
         Fragment : constant Node :=
           Member (Doc, Wanted, "messageContains");
      begin
         if Kind (Doc, Fragment) /= Null_Value
           and then not Contains_Ignoring_Case
                          (To_String (Outcome.Message),
                           Java_Text (Doc, Fragment))
         then
            Detail := "error message [" & Outcome.Message
              & "] does not contain [" & Java_Text (Doc, Fragment) & "]";
            return;
         end if;
      end;
      if Kind (Doc, Member (Doc, Wanted, "code")) /= Null_Value
        or else Kind (Doc, Member (Doc, Wanted, "sqlState")) /= Null_Value
      then
         Missing.Append
           (Missing_Check'(Check => To_Unbounded_String (Error_Code_Check),
                           Where => To_Unbounded_String (Where)));
      end if;
      Ok := True;
   end Check_Refusal;

   --  One step's expect block against its outcome (Compare.check).
   procedure Check
     (Doc     : Document;
      Expect  : Node;
      Outcome : Statement_Outcome;
      Where   : String;
      Ok      : out Boolean;
      Detail  : out Unbounded_String)
   is
      Wanted_Error : constant Node := Member (Doc, Expect, "error");
   begin
      Ok := False;
      Detail := Null_Unbounded_String;
      if Kind (Doc, Wanted_Error) = Object_Value then
         Check_Refusal (Doc, Wanted_Error, Outcome, Where, Ok, Detail);
         return;
      end if;
      if Outcome.Refused then
         Detail := "unexpected error: " & Outcome.Message;
         return;
      end if;
      if Kind (Doc, Expect) /= Object_Value then
         Ok := True;
         return;
      end if;

      if Has_Member (Doc, Expect, "value") then
         declare
            Want   : constant Text_Cell :=
              Expected_Cell (Doc, Member (Doc, Expect, "value"));
            Actual : constant Text_Cell := First_Cell (Outcome);
         begin
            if Norm (Want) /= Norm (Actual) then
               Detail := To_Unbounded_String
                 ("value [" & Image (Actual) & "] != expected ["
                  & Image (Want) & "]");
               return;
            end if;
         end;
      end if;

      declare
         Rows : constant Node := Member (Doc, Expect, "rows");
      begin
         if Kind (Doc, Rows) = Array_Value then
            declare
               Ordered : constant Boolean :=
                 Is_True (Doc, Member (Doc, Expect, "ordered"));
               Want    : Grids.Vector;
            begin
               for I in 1 .. Length (Doc, Rows) loop
                  declare
                     Row   : constant Node := Element (Doc, Rows, I);
                     Cells : Cell_Rows.Vector;
                  begin
                     for J in 1 .. Length (Doc, Row) loop
                        Cells.Append
                          (Expected_Cell (Doc, Element (Doc, Row, J)));
                     end loop;
                     Want.Append (Cells);
                  end;
               end loop;
               declare
                  Expected : constant Name_Vectors.Vector :=
                    Canonical (Want, Ordered);
                  Actual   : constant Name_Vectors.Vector :=
                    Canonical (Outcome.Rows, Ordered);
               begin
                  if not Name_Vectors."=" (Expected, Actual) then
                     Detail := To_Unbounded_String
                       ("rows differ: expected " & Shown (Expected)
                        & " got " & Shown (Actual));
                     return;
                  end if;
               end;
            end;
         end if;
      end;

      declare
         Wanted : Long_Long_Integer;
         Given  : Boolean;
      begin
         Integer_Field
           (Doc, Member (Doc, Expect, "rowCount"), Wanted, Given);
         if Given
           and then Long_Long_Integer (Outcome.Rows.Length) /= Wanted
         then
            Detail := To_Unbounded_String
              ("rowCount " & Img (Long_Long_Integer (Outcome.Rows.Length))
               & " != expected " & Img (Wanted));
            return;
         end if;
      end;

      declare
         Columns : constant Node := Member (Doc, Expect, "columns");
      begin
         if Kind (Doc, Columns) = Array_Value then
            if Natural (Outcome.Columns.Length) /= Length (Doc, Columns)
            then
               Detail := To_Unbounded_String
                 ("column count "
                  & Img (Long_Long_Integer (Outcome.Columns.Length))
                  & " != expected "
                  & Img (Long_Long_Integer (Length (Doc, Columns)))
                  & " " & Listed (Outcome.Columns));
               return;
            end if;
            for I in 1 .. Length (Doc, Columns) loop
               declare
                  Want : constant String :=
                    Java_Text (Doc, Element (Doc, Columns, I));
                  Got  : constant String := To_String (Outcome.Columns (I));
               begin
                  if not Equal_Ignoring_Case (Want, Got) then
                     Detail := To_Unbounded_String
                       ("column[" & Img (Long_Long_Integer (I - 1)) & "] ["
                        & Got & "] != expected [" & Want & "]");
                     return;
                  end if;
               end;
            end loop;
         end if;
      end;

      declare
         Wanted : Long_Long_Integer;
         Given  : Boolean;
      begin
         Integer_Field
           (Doc, Member (Doc, Expect, "updateCount"), Wanted, Given);
         if Given and then Outcome.Update_Count /= Wanted then
            Detail := To_Unbounded_String
              ("updateCount " & Img (Outcome.Update_Count)
               & " != expected " & Img (Wanted));
            return;
         end if;
      end;

      Ok := True;
   end Check;

   ------------------------
   --  One case          --
   ------------------------

   --  The backend a skip clause names for this runner, or "".
   function Skipped_For (Doc : Document; Test : Node) return String is
      Backends : constant Node :=
        Member (Doc, Member (Doc, Test, "skip"), "backends");
   begin
      for I in 1 .. Length (Doc, Backends) loop
         declare
            Name : constant String :=
              Text (Doc, Element (Doc, Backends, I));
         begin
            if Equal_Ignoring_Case (Name, Backend_Name)
              or else Equal_Ignoring_Case (Name, Transport_Name)
            then
               return Name;
            end if;
         end;
      end loop;
      return "";
   end Skipped_For;

   procedure Run_Case
     (Doc         : Document;
      Test        : Node;
      Where       : String;
      Status      : out Case_Status;
      Failed_Step : out Natural;
      Detail      : out Unbounded_String)
   is
      Steps   : constant Node := Member (Doc, Test, "steps");
      Current : Natural := 0;
   begin
      Status := Pass;
      Failed_Step := 0;
      Detail := Null_Unbounded_String;
      declare
         Conn : Frostlake.Connection :=
           Frostlake.Connect (To_String (Url));
      begin
         begin
            for Statement of Reset_Context loop
               declare
                  Outcome : constant Statement_Outcome :=
                    Run_Statement (Conn, To_String (Statement));
               begin
                  if Outcome.Refused then
                     Status := Error;
                     Detail := "resetContext failed on '" & Statement
                       & "': " & Outcome.Message;
                     exit;
                  end if;
               end;
            end loop;

            if Status = Pass then
               for Index in 1 .. Length (Doc, Steps) loop
                  Current := Index;
                  declare
                     Step    : constant Node := Element (Doc, Steps, Index);
                     Sql     : constant String :=
                       Text (Doc, Member (Doc, Step, "sql"));
                     Outcome : constant Statement_Outcome :=
                       Run_Statement (Conn, Sql);
                     Ok      : Boolean;
                     Why     : Unbounded_String;
                  begin
                     Check (Doc, Member (Doc, Step, "expect"), Outcome,
                            Where & " step" & Positive'Image (Index),
                            Ok, Why);
                     if not Ok then
                        Status := Fail;
                        Failed_Step := Index;
                        Detail := Why & "  [sql: " & Sql & "]";
                        exit;
                     end if;
                  end;
               end loop;
            end if;
         exception
            when E : others =>
               --  Not the engine's answer — the transport failed, or
               --  something on this side did — so no step can be judged.
               Status := Error;
               Failed_Step := Current;
               Detail := To_Unbounded_String (Describe (E));
         end;
         Conn.Close;
      end;
   exception
      when E : others =>
         Status := Error;
         Detail := To_Unbounded_String ("cannot connect: " & Describe (E));
   end Run_Case;

   --  One row of the report, and the tally.
   procedure Record_Case
     (Suite       : String;
      Test        : String;
      Status      : Case_Status;
      Failed_Step : Natural;
      Detail      : String;
      Millis      : Natural)
   is
      use Ada.Text_IO;
      Step_Text : constant String :=
        (if Failed_Step = 0 then ""
         else Img (Long_Long_Integer (Failed_Step)));
   begin
      Put_Line
        (Report_File,
         Clean (Suite) & Tab & Clean (Test) & Tab & Status_Name (Status)
         & Tab & Step_Text & Tab & Clean (Capped (Detail)) & Tab
         & Img (Long_Long_Integer (Millis)));
      case Status is
         when Pass =>
            Passed := Passed + 1;
         when Fail =>
            Failed := Failed + 1;
         when Error =>
            Errored := Errored + 1;
         when Skip =>
            Skipped := Skipped + 1;
      end case;
      if Status in Fail | Error and then Echoed < Max_Echoed then
         Echoed := Echoed + 1;
         Put_Line
           ("  " & Status_Name (Status) & " " & Suite & " / " & Test
            & (if Failed_Step = 0 then "" else " step " & Step_Text)
            & ": " & Clean (Capped (Detail)));
         Flush;
      end if;
   end Record_Case;

   ------------------------
   --  One suite file    --
   ------------------------

   procedure Run_Suite (Directory : String; File_Name : String) is
      Path     : constant String :=
        Ada.Directories.Compose (Directory, File_Name);
      Fallback : constant String := Ada.Directories.Base_Name (File_Name);
      Doc      : Document;
      Readable : Boolean := True;
   begin
      begin
         Doc := Parse (Read_File (Path));
      exception
         when E : others =>
            Record_Case (Fallback, "(suite file)", Error, 0,
                         "cannot read the suite: " & Describe (E), 0);
            Readable := False;
      end;
      if not Readable then
         return;
      end if;

      declare
         Top        : constant Node := Root (Doc);
         Named      : constant Node := Member (Doc, Top, "suite");
         Suite_Name : constant String :=
           (if Kind (Doc, Named) = String_Value then Text (Doc, Named)
            else Fallback);
         Tests      : constant Node := Member (Doc, Top, "tests");
      begin
         for I in 1 .. Length (Doc, Tests) loop
            declare
               Test      : constant Node := Element (Doc, Tests, I);
               Test_Name : constant String :=
                 Text (Doc, Member (Doc, Test, "name"));
               Hit       : constant String := Skipped_For (Doc, Test);
            begin
               if Hit /= "" then
                  Record_Case
                    (Suite_Name, Test_Name, Skip, 0,
                     "skipped for " & Hit & ": "
                     & Text (Doc, Member (Doc, Member (Doc, Test, "skip"),
                                          "reason")),
                     0);
               else
                  declare
                     use Ada.Real_Time;
                     Started     : constant Time := Clock;
                     Status      : Case_Status;
                     Failed_Step : Natural;
                     Detail      : Unbounded_String;
                  begin
                     Run_Case (Doc, Test, Suite_Name & "/" & Test_Name,
                               Status, Failed_Step, Detail);
                     Record_Case
                       (Suite_Name, Test_Name, Status, Failed_Step,
                        To_String (Detail),
                        Natural (To_Duration (Clock - Started) * 1000));
                  end;
               end if;
            end;
         end loop;
      end;
   end Run_Suite;

   ------------------------
   --  The report's note --
   ------------------------

   procedure Write_Missing_Apis (Path : String) is
      use Ada.Text_IO;
      Notes : File_Type;
      Seen  : Name_Vectors.Vector;
   begin
      Create (Notes, Out_File, Path);
      Put_Line (Notes,
                "# Missing APIs for backend `" & Backend_Name & "`");
      New_Line (Notes);
      Put_Line (Notes, "Checks the corpus asks for that this driver's"
                & " transport, the engine's HTTP protocol, cannot");
      Put_Line (Notes, "express. They are not failures: the expectations"
                & " are already in the suite files, so the");
      Put_Line (Notes, "day the API exists the checks light up without"
                & " touching a single test.");
      New_Line (Notes);
      for Item of Missing loop
         if not Seen.Contains (Item.Check) then
            Seen.Append (Item.Check);
         end if;
      end loop;
      if Seen.Is_Empty then
         Put_Line (Notes, "- none met in this run");
      end if;
      for Check_Text of Seen loop
         declare
            Count : Natural := 0;
            First : Unbounded_String;
         begin
            for Item of Missing loop
               if Item.Check = Check_Text then
                  Count := Count + 1;
                  if Count = 1 then
                     First := Item.Where;
                  end if;
               end if;
            end loop;
            Put_Line (Notes, "- " & To_String (Check_Text) & " —"
                      & Natural'Image (Count) & " check(s), first at "
                      & To_String (First));
         end;
      end loop;
      Close (Notes);
   end Write_Missing_Apis;

   Corpus      : constant String :=
     Ada.Environment_Variables.Value ("FL_CORPUS", "");
   Suites_Dir  : constant String := Corpus & "/suites";
   Report_Path : constant String :=
     Ada.Environment_Variables.Value
       ("FROSTLAKE_TESTKIT_REPORT", Default_Report);
   Filter      : constant String :=
     Ada.Environment_Variables.Value ("FROSTLAKE_TESTKIT_FILTER", "");
   Files       : Name_Vectors.Vector;
   Started     : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;

   use Ada.Text_IO;

begin
   --  The corpus is replayed only when FL_CORPUS names it.
   if Corpus = "" then
      Put_Line ("testkit [" & Backend_Name & "]: set FL_CORPUS to"
                & " frostlake's engine/src/test/resources/testkit to replay"
                & " the testkit corpus");
      return;
   end if;
   if not Holds_Suites (Suites_Dir) then
      Put_Line ("testkit [" & Backend_Name & "]: FL_CORPUS=" & Corpus
                & " holds no suites/*.json");
      Ada.Command_Line.Set_Exit_Status (2);
      return;
   end if;

   Url := To_Unbounded_String
     (Ada.Environment_Variables.Value ("FROSTLAKE_URL", ""));
   if Length (Url) = 0 then
      Put_Line ("testkit [" & Backend_Name & "]: FROSTLAKE_URL is not set;"
                & " point it at a running DatabaseHttpServer,"
                & " e.g. frostlake://127.0.0.1:18082");
      Ada.Command_Line.Set_Exit_Status (2);
      return;
   end if;

   --  Reached at all?  Otherwise every case would say so on its own line.
   begin
      declare
         Probe : Frostlake.Connection :=
           Frostlake.Connect (To_String (Url));
      begin
         Probe.Close;
      end;
   exception
      when E : others =>
         Put_Line ("testkit [" & Backend_Name & "]: cannot reach "
                   & To_String (Url) & ": " & Describe (E));
         Ada.Command_Line.Set_Exit_Status (2);
         return;
   end;

   declare
      use Ada.Directories;
      Search : Search_Type;
      Item   : Directory_Entry_Type;
   begin
      Start_Search (Search, Suites_Dir, "*.json",
                    [Ordinary_File => True, others => False]);
      while More_Entries (Search) loop
         Get_Next_Entry (Search, Item);
         if Filter = ""
           or else Ada.Strings.Fixed.Index (Simple_Name (Item), Filter) > 0
         then
            Files.Append (To_Unbounded_String (Simple_Name (Item)));
         end if;
      end loop;
      End_Search (Search);
   end;
   --  Name order, as every runner walks the corpus: account-level objects
   --  outlive the per-case reset, so the suites are order-sensitive.
   Name_Sorting.Sort (Files);

   if Directory_Of (Report_Path) /= ""
     and then not Ada.Directories.Exists (Directory_Of (Report_Path))
   then
      Ada.Directories.Create_Path (Directory_Of (Report_Path));
   end if;
   Create (Report_File, Out_File, Report_Path);
   Put_Line (Report_File, "suite" & Tab & "test" & Tab & "status" & Tab
             & "failedStep" & Tab & "detail" & Tab & "ms");

   Put_Line ("testkit [" & Backend_Name & "]:" & Natural'Image
               (Natural (Files.Length))
             & " suite file(s) from " & Suites_Dir & " against "
             & To_String (Url));
   Flush;

   for I in 1 .. Files.Last_Index loop
      Run_Suite (Suites_Dir, To_String (Files (I)));
      if I mod 100 = 0 then
         Put_Line ("  ..." & Positive'Image (I) & " of"
                   & Natural'Image (Natural (Files.Length)) & " files:"
                   & Natural'Image (Passed) & " passed,"
                   & Natural'Image (Failed + Errored) & " failed,"
                   & Natural'Image (Skipped) & " skipped");
         Flush;
      end if;
   end loop;
   Close (Report_File);

   Write_Missing_Apis
     ((if Directory_Of (Report_Path) = "" then ""
       else Directory_Of (Report_Path) & "/")
      & "missing-apis-" & Backend_Name & ".md");

   Put_Line ("  report: " & Report_Path & " —"
             & Natural'Image (Passed + Failed + Errored + Skipped)
             & " case(s): PASS" & Natural'Image (Passed)
             & ", FAIL" & Natural'Image (Failed)
             & ", ERROR" & Natural'Image (Errored)
             & ", SKIP" & Natural'Image (Skipped)
             & ", in"
             & Natural'Image
                 (Natural (Ada.Real_Time.To_Duration
                             (Ada.Real_Time."-" (Ada.Real_Time.Clock,
                                                 Started))))
             & " s");
   if not Missing.Is_Empty then
      Put_Line ("  checks needing an API the transport lacks:"
                & Natural'Image (Natural (Missing.Length))
                & " (see missing-apis-" & Backend_Name & ".md)");
   end if;
   Put_Line ("testkit [" & Backend_Name & "]:" & Natural'Image (Passed)
             & " passed," & Natural'Image (Failed + Errored) & " failed,"
             & Natural'Image (Skipped) & " skipped");

   if Failed + Errored > 0 then
      Ada.Command_Line.Set_Exit_Status (1);
   end if;
end Testkit_Runner;
