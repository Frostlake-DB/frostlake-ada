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

   procedure Start_Raw
     (Reply : String;
      Port  : out Positive);
   --  Begins serving Reply byte for byte, status line and headers included,
   --  for replies no HTTP server would send.  After answering, it holds each
   --  connection open until the client closes its end, which Hang_Ups
   --  counts, or two seconds pass.  A previous server is stopped first.

   function Hang_Ups return Natural;
   --  How many held connections the client closed since Start_Raw.

   procedure Start_Script (Port : out Positive);
   --  Begins serving the replies Add_Reply queues, one per request, in
   --  order — for a conversation, where every reply may differ.  A request
   --  past the last queued reply is answered HTTP 500 with an "unscripted
   --  request" failure, and counted like any other, so a request the
   --  driver should not have sent shows up in Request_Count instead of
   --  hanging the suite.  A previous server is stopped first.

   Hang_Up : constant Natural := 0;
   --  As Add_Reply's Status: read the request, then close without a word.

   Silence : constant Natural := 1;
   --  As Add_Reply's Status: read the request, then say nothing until the
   --  client lets go, which Hang_Ups counts, or two seconds pass.

   procedure Add_Reply (Status : Natural; Content : String := "");
   --  Queues the next reply of a Start_Script server: Content as a JSON
   --  body with a Content-Length, or Hang_Up or Silence.

   procedure Stop;
   --  Idempotent.  Every test path must reach it: the serving task is
   --  library-level, and the program will not exit while one is blocked
   --  in accept.

   function Request_Count return Natural;

   function Request_Text (Index : Positive) return String;
   --  The raw text (request line, headers, body) of the Index-th request
   --  since Start.

end Loopback;
