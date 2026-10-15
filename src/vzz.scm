;; vzz -- a sleep-timer for video.
;;
;; Plays VIDEO_FILE in mpv for --duration minutes, then stops it. Optionally
;; fades the volume to silence and/or the picture to black before stopping,
;; and optionally powers the machine off afterwards.
;;
;; mpv is started with --input-ipc-server, which creates a Unix domain
;; socket that accepts JSON commands. This process connects to that socket
;; and, once a second, nudges the volume/brightness/contrast properties
;; toward the requested fades and -- once --duration has elapsed -- sends
;; "quit". There's no egg for Unix domain sockets on this CHICKEN version,
;; so the socket client below is a thin FFI wrapper over plain POSIX
;; socket()/connect()/read()/write().

(import scheme
        (chicken base)
        (chicken condition)
        (chicken file)
        (chicken foreign)
        (chicken format)
        (chicken process)
        (chicken process-context)
        (chicken process-context posix)
        (chicken process signal)
        (chicken string)
        (chicken time))

(foreign-declare "
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>

static int vzz_unix_connect(const char *path) {
  struct sockaddr_un addr;
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) return -1;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
  if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
    int e = errno;
    close(fd);
    errno = e;
    return -1;
  }
  return fd;
}

static int vzz_set_nonblocking(int fd) {
  int flags = fcntl(fd, F_GETFL, 0);
  if (flags < 0) return -1;
  return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

/* Returned string is only valid until the next call -- callers (via the
   c-string return type) get a fresh Scheme string copied out of it right
   away, so that's fine. Empty string covers both 'nothing to read right
   now' (EAGAIN) and 'peer closed'; we only use this to drain and discard
   mpv's replies, so the two cases don't need telling apart. */
static char vzz_readbuf[4096];
static char *vzz_read_chunk(int fd) {
  int n = read(fd, vzz_readbuf, sizeof(vzz_readbuf) - 1);
  if (n <= 0) return \"\";
  vzz_readbuf[n] = 0;
  return vzz_readbuf;
}
")

(define unix-connect (foreign-lambda int "vzz_unix_connect" c-string))
(define set-nonblocking! (foreign-lambda int "vzz_set_nonblocking" int))
(define c-write (foreign-lambda int "write" int c-string int))
(define read-chunk (foreign-lambda c-string "vzz_read_chunk" int))
(define c-close (foreign-lambda int "close" int))

;; Paths of temp files currently in use, so the SIGINT handler below can
;; clean them up before exiting.
(define temp-files-in-use '())

;; CHICKEN's default SIGINT handling drops into a debug prompt instead of
;; exiting. On Ctrl+C the terminal also delivers SIGINT directly to mpv
;; (same foreground process group), which quits on its own; this handler
;; just makes sure vzz itself exits promptly afterwards, without going
;; through the "we sent quit" path, so --shutdown is correctly skipped.
(set-signal-handler!
  signal/int
  (lambda (s)
    (for-each (lambda (path) (when (file-exists? path) (delete-file path)))
              temp-files-in-use)
    (exit 130)))

(define prog-name "vzz")

(define (usage-port status)
  (if (= status 0) (current-output-port) (current-error-port)))

(define (usage-and-exit status)
  (let ((port (usage-port status)))
    (fprintf port "usage: ~a VIDEO_FILE --duration MINUTES [options]\n\n" prog-name)
    (fprintf port "Play VIDEO_FILE for MINUTES minutes, then stop.\n\n")
    (fprintf port "options:\n")
    (fprintf port "  --fade-audio-at MINUTES  fade volume to silence, reaching 0 at --duration\n")
    (fprintf port "  --fade-video-at MINUTES  fade picture to black, reaching black at --duration\n")
    (fprintf port "  --fullscreen             play mpv fullscreen instead of windowed\n")
    (fprintf port "  --shutdown               power off once playback stops naturally\n")
    (fprintf port "  -h, --help               show this message\n"))
  (exit status))

(define (die . args)
  (fprintf (current-error-port) "~a: " prog-name)
  (apply fprintf (current-error-port) args)
  (newline (current-error-port))
  (usage-and-exit 1))

(define (parse-number-arg name value)
  (or (string->number value)
      (die "~a must be a number, got ~s" name value)))

;; Returns (values video-file duration-minutes fade-audio-minutes
;;         fade-video-minutes fullscreen? shutdown?). fade-*-minutes are #f
;; when not given.
(define (parse-args args)
  (let loop ((args args) (video #f) (duration #f)
             (fade-audio #f) (fade-video #f)
             (fullscreen #f) (shutdown #f))
    (define (need-value! name)
      (when (null? (cdr args)) (die "~a requires a value" name)))
    (cond
      ((null? args)
       (unless video (die "missing VIDEO_FILE"))
       (unless duration (die "missing --duration"))
       (values video duration fade-audio fade-video fullscreen shutdown))
      ((member (car args) '("-h" "--help"))
       (usage-and-exit 0))
      ((string=? (car args) "--duration")
       (need-value! "--duration")
       (loop (cddr args) video (parse-number-arg "--duration" (cadr args))
             fade-audio fade-video fullscreen shutdown))
      ((string=? (car args) "--fade-audio-at")
       (need-value! "--fade-audio-at")
       (loop (cddr args) video duration
             (parse-number-arg "--fade-audio-at" (cadr args)) fade-video
             fullscreen shutdown))
      ((string=? (car args) "--fade-video-at")
       (need-value! "--fade-video-at")
       (loop (cddr args) video duration fade-audio
             (parse-number-arg "--fade-video-at" (cadr args))
             fullscreen shutdown))
      ((string=? (car args) "--fullscreen")
       (loop (cdr args) video duration fade-audio fade-video #t shutdown))
      ((string=? (car args) "--shutdown")
       (loop (cdr args) video duration fade-audio fade-video fullscreen #t))
      ((and (positive? (string-length (car args))) (char=? (string-ref (car args) 0) #\-))
       (die "unknown option ~a" (car args)))
      (video (die "unexpected extra argument ~a" (car args)))
      (else (loop (cdr args) (car args) duration fade-audio fade-video fullscreen shutdown)))))

(define (minutes->seconds m) (inexact->exact (round (* m 60))))

(define (validate! video duration fade-audio fade-video)
  (unless (file-exists? video) (die "no such file: ~a" video))
  (unless (positive? duration) (die "--duration must be greater than 0"))
  (for-each
    (lambda (name value)
      (when (and value (or (negative? value) (>= value duration)))
        (die "~a must be between 0 and --duration (~a)" name duration)))
    (list "--fade-audio-at" "--fade-video-at")
    (list fade-audio fade-video)))

(define (find-on-path name)
  (let loop ((dirs (string-split (or (get-environment-variable "PATH") "") ":")))
    (cond
      ((null? dirs) #f)
      (else
       (let ((candidate (sprintf "~a/~a" (car dirs) name)))
         (if (and (file-exists? candidate) (file-executable? candidate))
             candidate
             (loop (cdr dirs))))))))

(define (tmp-dir)
  (or (get-environment-variable "TMPDIR") "/tmp"))

(define (tmp-path label)
  (sprintf "~a/vzz-~a-~a" (tmp-dir) (current-process-id) label))

(define (delete-file-if-exists path)
  (when (file-exists? path) (delete-file path)))

(define (process-exited? pid)
  (receive (wpid normal? status) (process-wait pid #t)
    (and (not (zero? wpid)) (list normal? status))))

;; Fraction of a fade still remaining: 1 at fade-at, 0 at duration.
(define (remaining-fraction fade-at duration elapsed)
  (let ((span (- duration fade-at)))
    (if (<= span 0)
        0.0
        (max 0.0 (min 1.0 (exact->inexact (/ (- duration elapsed) span)))))))

(define (ipc-send! fd message)
  (c-write fd message (string-length message)))

(define (ipc-set-property! fd name value)
  (ipc-send! fd (sprintf "{\"command\":[\"set_property\",\"~a\",~a]}\n" name value)))

(define (ipc-quit! fd)
  (ipc-send! fd "{\"command\":[\"quit\"]}\n"))

;; Connects to mpv's IPC socket, retrying once a second (mpv needs a brief
;; moment after exec to create it). Gives up and returns #f if mpv exits
;; first, or after CONNECT-TIMEOUT-SECONDS.
(define connect-timeout-seconds 10)

(define (connect-ipc path pid)
  (let loop ((tries 0))
    (let ((fd (unix-connect path)))
      (cond
        ((>= fd 0) fd)
        ((process-exited? pid) #f)
        ((>= tries connect-timeout-seconds) #f)
        (else (sleep 1) (loop (add1 tries)))))))

;; One tick of the fade loop: nudge properties toward the fade targets for
;; the current ELAPSED time. SENT-QUIT? tracks whether we've already told
;; mpv to quit, so we don't resend it every second.
(define (fade-tick! fd elapsed duration-seconds fade-audio-seconds fade-video-seconds)
  (when (and fade-audio-seconds (>= elapsed fade-audio-seconds))
    (ipc-set-property!
      fd "volume"
      (* 100.0 (remaining-fraction fade-audio-seconds duration-seconds elapsed))))
  (when (and fade-video-seconds (>= elapsed fade-video-seconds))
    (let ((value (* -100.0 (- 1.0 (remaining-fraction fade-video-seconds duration-seconds elapsed)))))
      (ipc-set-property! fd "contrast" value)
      (ipc-set-property! fd "brightness" value))))

;; Polls once a second until mpv exits, nudging fades and sending "quit"
;; once --duration has elapsed. Returns #t ("stopped naturally", i.e. we're
;; the ones who sent quit) or #f (mpv exited some other way -- the user
;; quit it, closed the window, Ctrl+C, etc). Exits the whole program if mpv
;; exits abnormally.
(define (poll-until-done fd pid duration-seconds fade-audio-seconds fade-video-seconds socket-path)
  (let ((start-seconds (current-seconds)))
    (let loop ((sent-quit? #f))
      (read-chunk fd) ; drain mpv's replies, discard them
      (let ((exit-info (process-exited? pid)))
        (cond
          (exit-info
           (unless (and (car exit-info) (zero? (cadr exit-info)))
             (fprintf (current-error-port) "~a: mpv exited abnormally\n" prog-name)
             (c-close fd)
             (delete-file-if-exists socket-path)
             (exit 1))
           sent-quit?)
          (else
           (let ((elapsed (- (current-seconds) start-seconds)))
             (fade-tick! fd elapsed duration-seconds fade-audio-seconds fade-video-seconds)
             (cond
               ((and (not sent-quit?) (>= elapsed duration-seconds))
                (ipc-quit! fd)
                (sleep 1)
                (loop #t))
               ((and sent-quit? (> elapsed (+ duration-seconds 5)))
                (fprintf (current-error-port)
                         "~a: mpv didn't respond to quit, killing it\n" prog-name)
                (process-signal pid signal/kill)
                (process-wait pid)
                #t)
               (else (sleep 1) (loop sent-quit?))))))))))

(define (run-mpv video duration fade-audio fade-video fullscreen)
  (let* ((socket-path (tmp-path "ipc.sock"))
         (duration-seconds (minutes->seconds duration))
         (fade-audio-seconds (and fade-audio (minutes->seconds fade-audio)))
         (fade-video-seconds (and fade-video (minutes->seconds fade-video)))
         (mpv-args
           (append
             (list video
                   "--loop-file=inf"
                   (sprintf "--input-ipc-server=~a" socket-path))
             (if fullscreen (list "--fullscreen") '()))))
    (delete-file-if-exists socket-path)
    (set! temp-files-in-use (list socket-path))
    (handle-exceptions exn
      (begin
        (delete-file-if-exists socket-path)
        (fprintf (current-error-port) "~a: failed to run mpv: ~a\n"
                 prog-name ((condition-property-accessor 'exn 'message) exn))
        (exit 1))
      (let* ((pid (process-run "mpv" mpv-args))
             (fd (connect-ipc socket-path pid)))
        (unless fd
          (let ((already-dead (process-exited? pid)))
            (if already-dead
                (fprintf (current-error-port) "~a: mpv exited abnormally\n" prog-name)
                (begin
                  (fprintf (current-error-port)
                           "~a: timed out waiting for mpv's IPC socket\n" prog-name)
                  (process-signal pid signal/term)
                  (process-wait pid))))
          (delete-file-if-exists socket-path)
          (exit 1))
        (set-nonblocking! fd)
        (let ((stopped-naturally?
                (poll-until-done fd pid duration-seconds fade-audio-seconds
                                  fade-video-seconds socket-path)))
          (c-close fd)
          (delete-file-if-exists socket-path)
          stopped-naturally?)))))

(define (shutdown-machine!)
  (print "vzz: playback finished, shutting down...")
  (receive (_ normal? status) (process-wait (process-run "sudo" (list "shutdown" "-h" "now")))
    (unless (and normal? (zero? status))
      (fprintf (current-error-port) "~a: shutdown command failed\n" prog-name))))

(define (main)
  (receive (video duration fade-audio fade-video fullscreen shutdown)
      (parse-args (command-line-arguments))
    (validate! video duration fade-audio fade-video)
    (unless (find-on-path "mpv")
      (fprintf (current-error-port)
               "~a: mpv not found in PATH; install it from https://mpv.io\n" prog-name)
      (exit 1))
    (let ((stopped-naturally? (run-mpv video duration fade-audio fade-video fullscreen)))
      (when (and shutdown stopped-naturally?)
        (shutdown-machine!)))))

(main)
