with Ada.Command_Line;
with Ada.Directories;
with Ada.Environment_Variables;

with GNAT.OS_Lib;
with GNAT.Sockets;

with Frostlake.Http;
with Test_Support;

package body Corpus_Tests is

   use Test_Support;

   Label : constant String := "testkit corpus";

   function Img (Value : Integer) return String is
      Raw : constant String := Integer'Image (Value);
   begin
      if Raw (Raw'First) = ' ' then
         return Raw (Raw'First + 1 .. Raw'Last);
      end if;
      return Raw;
   end Img;

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

   --  The runner, built into the same bin/ as this program.
   function Runner return String is
     (Ada.Directories.Containing_Directory (Ada.Command_Line.Command_Name)
      & "/testkit_runner");

   function Free_Port return Positive is
      use GNAT.Sockets;
      Probe   : Socket_Type;
      Address : Sock_Addr_Type;
   begin
      Create_Socket (Probe);
      Bind_Socket
        (Probe,
         (Family => Family_Inet,
          Addr   => Inet_Addr ("127.0.0.1"),
          Port   => 0));
      Address := Get_Socket_Name (Probe);
      Close_Socket (Probe);
      return Positive (Address.Port);
   end Free_Port;

   --  The runner reads the server from FROSTLAKE_URL, and exits non-zero
   --  when any case failed or errored.
   procedure Replay (Dsn_Base : String) is
      No_Arguments : GNAT.OS_Lib.Argument_List (1 .. 0);
      Status : Integer;
   begin
      Ada.Environment_Variables.Set ("FROSTLAKE_URL", Dsn_Base);
      Status := GNAT.OS_Lib.Spawn (Runner, No_Arguments);
      Check (Status = 0, Label & ": " & Runner & " exited with status"
             & Integer'Image (Status));
   end Replay;

   --  Boots a DatabaseHttpServer from Classpath on a free port, with Home
   --  as its user.home, replays the corpus once it answers, and stops it.
   procedure Replay_On_Own_Server (Classpath : String; Home : String) is
      use GNAT.OS_Lib;
      Java_Home : constant String :=
        Ada.Environment_Variables.Value ("JAVA_HOME", "");
      Java : constant String :=
        (if Java_Home /= "" then Java_Home & "/bin/java" else "java");
      Java_Path : String_Access :=
        (if Java_Home /= "" then new String'(Java)
         else Locate_Exec_On_Path ("java"));
      Port : constant Positive := Free_Port;
      Args : Argument_List (1 .. 5);
      Pid  : Process_Id;
      Healthy : Boolean := False;
   begin
      if Java_Path = null then
         Record_Failure (Label & ": no java on PATH and no JAVA_HOME");
         return;
      end if;
      Args (1) := new String'("-Duser.home=" & Home);
      Args (2) := new String'("-cp");
      Args (3) := new String'(Classpath);
      Args (4) := new String'("dev.frostlake.http.DatabaseHttpServer");
      Args (5) := new String'(Img (Port));
      Pid := Non_Blocking_Spawn
        (Program_Name => Java_Path.all,
         Args         => Args,
         Output_File  => "db-engine.log",
         Err_To_Out   => True);
      for A of Args loop
         Free (A);
      end loop;
      Free (Java_Path);
      if Pid = Invalid_Pid then
         Record_Failure (Label & ": could not start the server");
         return;
      end if;
      for Attempt in 1 .. 100 loop
         begin
            declare
               Reply : constant Frostlake.Http.Reply := Frostlake.Http.Get
                 ("127.0.0.1", Port, "/api/health",
                  Open_Timeout => 1.0, Read_Timeout => 5.0);
            begin
               if Reply.Status in 200 .. 299 then
                  Healthy := True;
               end if;
            end;
         exception
            when Frostlake.Connection_Error =>
               null;
         end;
         exit when Healthy;
         delay 0.2;
      end loop;
      if not Healthy then
         Record_Failure
           (Label & ": server never became healthy — see db-engine.log");
      else
         Replay ("frostlake://127.0.0.1:" & Img (Port));
      end if;
      Kill (Pid, Hard_Kill => True);
   end Replay_On_Own_Server;

   procedure Run is
      Corpus : constant String :=
        Ada.Environment_Variables.Value ("FL_CORPUS", "");
      Url : constant String :=
        Ada.Environment_Variables.Value ("FROSTLAKE_URL", "");
      Classpath : constant String :=
        Ada.Environment_Variables.Value ("FROSTLAKE_CLASSPATH", "");
   begin
      if Corpus = "" then
         Skip (Label, "set FL_CORPUS to frostlake's"
               & " engine/src/test/resources/testkit to replay the testkit"
               & " corpus");
         return;
      end if;
      if not Holds_Suites (Corpus & "/suites") then
         Record_Failure (Label & ": FL_CORPUS=" & Corpus
                         & " holds no suites/*.json");
         return;
      end if;
      if Url = "" and then Classpath = "" then
         Skip (Label, "neither FROSTLAKE_URL nor FROSTLAKE_CLASSPATH names"
               & " an engine");
         return;
      end if;
      if not GNAT.OS_Lib.Is_Executable_File (Runner) then
         Record_Failure (Label & ": no runner at " & Runner);
         return;
      end if;
      if Url /= "" then
         Replay (Url);
         return;
      end if;
      declare
         Home : constant String :=
           Ada.Environment_Variables.Value ("TMPDIR", "/tmp")
           & "/frostlake-ada-testkit-"
           & Img (GNAT.OS_Lib.Pid_To_Integer
                    (GNAT.OS_Lib.Current_Process_Id));
      begin
         if Ada.Directories.Exists (Home) then
            Ada.Directories.Delete_Tree (Home);
         end if;
         Ada.Directories.Create_Path (Home);
         Replay_On_Own_Server (Classpath, Home);
         --  It holds nothing but the stages the corpus wrote.
         begin
            Ada.Directories.Delete_Tree (Home);
         exception
            when Ada.Directories.Use_Error =>
               null;
         end;
      end;
   end Run;

end Corpus_Tests;
