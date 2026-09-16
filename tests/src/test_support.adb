with Ada.Text_IO;

package body Test_Support is

   Pass_Count : Natural := 0;
   Fail_Count : Natural := 0;
   Skip_Count : Natural := 0;

   procedure Note (Message : String) is
   begin
      Ada.Text_IO.Put_Line (Message);
      Ada.Text_IO.Flush;
   end Note;

   procedure Check (Condition : Boolean; Label : String) is
   begin
      if Condition then
         Pass_Count := Pass_Count + 1;
      else
         Fail_Count := Fail_Count + 1;
         Ada.Text_IO.Put_Line ("FAIL: " & Label);
         Ada.Text_IO.Flush;
      end if;
   end Check;

   procedure Check_Equal (Got : String; Want : String; Label : String) is
   begin
      if Got = Want then
         Pass_Count := Pass_Count + 1;
      else
         Fail_Count := Fail_Count + 1;
         Ada.Text_IO.Put_Line
           ("FAIL: " & Label & " — got """ & Got & """, want """ & Want
            & '"');
         Ada.Text_IO.Flush;
      end if;
   end Check_Equal;

   procedure Check_Equal
     (Got   : Long_Long_Integer;
      Want  : Long_Long_Integer;
      Label : String) is
   begin
      if Got = Want then
         Pass_Count := Pass_Count + 1;
      else
         Fail_Count := Fail_Count + 1;
         Ada.Text_IO.Put_Line
           ("FAIL: " & Label & " — got" & Long_Long_Integer'Image (Got)
            & ", want" & Long_Long_Integer'Image (Want));
         Ada.Text_IO.Flush;
      end if;
   end Check_Equal;

   procedure Record_Failure (Label : String) is
   begin
      Fail_Count := Fail_Count + 1;
      Ada.Text_IO.Put_Line ("FAIL: " & Label);
      Ada.Text_IO.Flush;
   end Record_Failure;

   procedure Skip (Label : String; Why : String) is
   begin
      Skip_Count := Skip_Count + 1;
      Ada.Text_IO.Put_Line ("SKIP: " & Label & " — " & Why);
      Ada.Text_IO.Flush;
   end Skip;

   function Passed return Natural is
   begin
      return Pass_Count;
   end Passed;

   function Failed return Natural is
   begin
      return Fail_Count;
   end Failed;

   function Skipped return Natural is
   begin
      return Skip_Count;
   end Skipped;

end Test_Support;
