;;;; Copyright (c) 2016 Henry Harrington <henry.harrington@gmail.com>
;;;; This code is licensed under the MIT license.

(in-package :mezzano.supervisor)

(sys.int::define-lap-function sys.int::%interrupt-state (())
  (mezzano.lap.arm64:mrs :x9 :daif)
  (mezzano.lap.arm64:ldr :x0 (:constant t))
  (mezzano.lap.arm64:ands :xzr :x9 :x9)
  (mezzano.lap.arm64:csel.ne :x0 :x26 :x0)
  (mezzano.lap.arm64:movz :x5 #.(ash 1 sys.int::+n-fixnum-bits+))
  (mezzano.lap.arm64:ret))

(sys.int::define-lap-function %disable-interrupts (())
  (mezzano.lap.arm64:msr :daifset #b1111)
  (mezzano.lap.arm64:ret))

(sys.int::define-lap-function %enable-interrupts (())
  (mezzano.lap.arm64:msr :daifclr #b1111)
  (mezzano.lap.arm64:ret))

(sys.int::define-lap-function %call-on-wired-stack-without-interrupts ((function unused &optional arg1 arg2 arg3))
  ;; Argument setup.
  (mezzano.lap.arm64:orr :x6 :xzr :x0) ; function
  (mezzano.lap.arm64:add :x0 :sp 0) ; sp
  (mezzano.lap.arm64:orr :x1 :xzr :x29) ; fp
  ;; Test if interrupts are enabled.
  (mezzano.lap.arm64:mrs :x9 :daif)
  (mezzano.lap.arm64:cbz :x9 INTERRUPTS-ENABLED)
  ;; Interrupts are already disabled, tail-call to the function.
  (mezzano.lap.arm64:ldr :x9 (:object :x6 0))
  (mezzano.lap.arm64:br :x9)
  INTERRUPTS-ENABLED
  ;; Build a frame and save the old stack pointer.
  (mezzano.lap.arm64:stp :x29 :x30 (:pre :sp -16))
  (:gc :no-frame :layout #*0)
  (mezzano.lap.arm64:add :x29 :sp :xzr)
  (:gc :frame)
  ;; Disable interrupts after setting up the frame, not before.
  ;; Modifying the normal stack may cause page-faults which can't
  ;; occur with interrupts disabled.
  (mezzano.lap.arm64:msr :daifset #b1111)
  ;; Switch over to the wired stack.
  (mezzano.lap.arm64:msr :spsel 1)
  ;; Call function, arguments were setup above.
  (mezzano.lap.arm64:ldr :x9 (:object :x6 0))
  (mezzano.lap.arm64:blr :x9)
  (:gc :frame :multiple-values 0)
  ;; Switch back to the old stack.
  ;; Do not restore frame & stack pointer here, that would touch the old stack with
  ;; interrupts disabled.
  (mezzano.lap.arm64:msr :spsel 0)
  ;; Reenable interrupts, must not be done when on the wired stack.
  (mezzano.lap.arm64:msr :daifclr #b1111)
  ;; Now safe to restore the frame pointer.
  (mezzano.lap.arm64:ldp :x29 :x30 (:post :sp 16))
  (:gc :no-frame :multiple-values 0)
  ;; Done, return.
  (mezzano.lap.arm64:ret))

(sys.int::define-lap-function %read-esr-el1 (())
  (mezzano.lap.arm64:mrs :x0 :esr-el1)
  (mezzano.lap.arm64:add :x0 :xzr :x0 :lsl #.sys.int::+n-fixnum-bits+)
  (mezzano.lap.arm64:ret))

(sys.int::define-lap-function %read-far-el1 (())
  (mezzano.lap.arm64:mrs :x0 :far-el1)
  (mezzano.lap.arm64:add :x0 :xzr :x0 :lsl #.sys.int::+n-fixnum-bits+)
  (mezzano.lap.arm64:ret))

(defun unhandled-interrupt (interrupt-frame name)
  (panic "Unhandled " name " interrupt."
         " SPSR: " (interrupt-frame-raw-register interrupt-frame :rflags)
         " PC: " (interrupt-frame-raw-register interrupt-frame :rip)
         " x30: " (interrupt-frame-raw-register interrupt-frame :cs)
         " SP: " (interrupt-frame-raw-register interrupt-frame :rsp)
         " ESR: " (%read-esr-el1)
         " FAR: " (%read-far-el1)))

(defun %page-fault-handler (interrupt-frame fault-addr reason)
  (when (and (boundp '*page-fault-hook*)
             *page-fault-hook*)
    ;; FIXME: This doesn't work when the hook was bound in SP_EL0,
    ;; it doesn't switch back to EL0, which will leave SP_EL1 pointing at the EL0
    ;; stack. Even if it did switch back to SP_EL0 it would also need to restore
    ;; the original SP_EL1.
    (funcall *page-fault-hook* interrupt-frame reason fault-addr))
  (cond ((not *paging-disk*)
         (unhandled-interrupt interrupt-frame "early-page-fault"))
        ((logtest #x3C0 (interrupt-frame-raw-register interrupt-frame :rflags))
         ;; IRQs must be enabled when a page fault occurs.
         (unhandled-interrupt interrupt-frame "page-fault-no-irqs"))
        ((or (<= 0 fault-addr (1- (* 2 1024 1024 1024)))
             (<= (ash sys.int::+address-tag-stack+ sys.int::+address-tag-shift+)
                 fault-addr
                 (+ (ash sys.int::+address-tag-stack+ sys.int::+address-tag-shift+)
                    (* 512 1024 1024 1024))))
         ;; Pages below 2G are wired and should never be unmapped or protected.
         ;; Same for pages in the wired stack area.
         (unhandled-interrupt interrupt-frame "wired-page-fault"))
        ((eql reason :write-to-ro)
         ;; Copy on write page, might not return.
         (snapshot-clone-cow-page-via-page-fault interrupt-frame fault-addr))
        ((eql reason :not-present)
         ;; Non-present page. Try to load it from the store.
         ;; Might not return.
         (wait-for-page-via-interrupt interrupt-frame fault-addr))
        (t
         (unhandled-interrupt interrupt-frame "page-fault"))))

(defun %instruction-abort-handler (interrupt-frame fault-addr esr)
  (let ((status (ldb (byte 5 0) esr)))
    (case status
      (#x05 ;; EL1 translation fault (page not mapped).
       (%page-fault-handler interrupt-frame fault-addr :not-present))
      (t
       (unhandled-interrupt interrupt-frame "instruction-abort")))))

(defun %data-abort-handler (interrupt-frame fault-addr esr)
  (let ((status (ldb (byte 5 0) esr)))
    (case status
      (#x05 ;; EL1 translation fault (page not mapped).
       (%page-fault-handler interrupt-frame fault-addr :not-present))
      (t
       (unhandled-interrupt interrupt-frame "data-abort")))))

(defun %synchronous-el0-handler (interrupt-frame)
  (let* ((esr (%read-esr-el1))
         (class (ldb (byte 6 26) esr)))
    (case class
      (#x21
       (%instruction-abort-handler interrupt-frame (%read-far-el1) esr))
      (#x25
       (%data-abort-handler interrupt-frame (%read-far-el1) esr))
      (t
       (unhandled-interrupt interrupt-frame "synchronous-el0")))))

(defun %irq-el0-handler (interrupt-frame)
  (unhandled-interrupt interrupt-frame "irq-el0"))

(defun %fiq-el0-handler (interrupt-frame)
  (unhandled-interrupt interrupt-frame "fiq-el0"))

(defun %serror-el0-handler (interrupt-frame)
  (unhandled-interrupt interrupt-frame "serror-el0"))

(defun %synchronous-elx-handler (interrupt-frame)
  (let* ((esr (%read-esr-el1))
         (class (ldb (byte 6 26) esr)))
    (case class
      (#x21
       (%instruction-abort-handler interrupt-frame (%read-far-el1) esr))
      (#x25
       (%data-abort-handler interrupt-frame (%read-far-el1) esr))
      (t
       (unhandled-interrupt interrupt-frame "synchronous-elx")))))

(defun %irq-elx-handler (interrupt-frame)
  (unhandled-interrupt interrupt-frame "irq-elx"))

(defun %fiq-elx-handler (interrupt-frame)
  (unhandled-interrupt interrupt-frame "fiq-elx"))

(defun %serror-elx-handler (interrupt-frame)
  (unhandled-interrupt interrupt-frame "serror-elx"))

(defun platform-mask-irq (vector)
  (gic-mask-interrupt vector))

(defun platform-unmask-irq (vector)
  (gic-unmask-interrupt vector))

(defun platform-attach-irq (vector handler)
  (gic-hook-interrupt vector handler))
