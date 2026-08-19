--  A one-trick HTTP server on 127.0.0.1: answers every request with the
--  configured status and body, and remembers what it was asked.  Lets the
--  driver's whole connect/execute flow run without a JVM.

package Loopback is

   procedure Start
     (Content        : String;
      Port           : out Positive;
      Status         : Natural := 200;
      Content_Length : Boolean := True);
   --  Begins serving.  With Content_Length False the reply omits the
   --  header and the body ends when the connection closes — the read-to-
   --  EOF path.  A previous server is stopped first.

   procedure Stop;
   --  Idempotent.  Every test path must reach it: the serving task is
   --  library-level, and the program will not exit while one is blocked
   --  in accept.

   function Request_Count return Natural;

   function Request_Text (Index : Positive) return String;
   --  The raw text (request line, headers, body) of the Index-th request
   --  since Start.

end Loopback;
