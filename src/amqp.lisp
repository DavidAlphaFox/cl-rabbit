(in-package :cl-rabbit)

(declaim (optimize (speed 0) (safety 3) (debug 3)))

(define-condition rabbitmq-error (error)
  ((type :type keyword
         :initarg :type
         :reader rabbitmq-error/type
         :documentation "The response type as returned by the AMQP call"))
  (:report (lambda (condition out)
             (format out "AMQP error: ~s" (rabbitmq-error/type condition))))
  (:documentation "Error that is raised when an AMQP call fails"))

(define-condition rabbitmq-server-error (error)
  ((type :type keyword
         :initarg :type
         :reader rabbitmq-server-error/type
         :documentation "Exception type as returned by the server"))
  (:report (lambda (condition out)
             (format out "RPC error: ~s" (slot-value condition 'type)))))

(defclass message ()
  ((body :type (simple-array (unsigned-byte 8) (*))
         :initarg :body
         :reader message/body)))

(defmethod print-object ((obj message) stream)
  (print-unreadable-object (obj stream :type t :identity nil)
    (if (slot-boundp obj 'body)
        (format stream "LENGTH ~a" (array-dimension (slot-value obj 'body) 0))
        (format stream "NOT-BOUND"))))

(defun make-envelope-message (value)
  (make-instance 'message :body (bytes->array (getf value 'body))))

(defclass envelope ()
  ((channel      :type integer
                 :initarg :channel
                 :reader envelope/channel)
   (consumer-tag :type string
                 :initarg :consumer-tag
                 :reader envelope/consumer-tag)
   (delivery-tag :type integer
                 :initarg :delivery-tag
                 :reader envelope/delivery-tag)
   (exchange     :type string
                 :initarg :exchange
                 :reader envelope/exchange)
   (routing-key  :type string
                 :initarg :routing-key
                 :reader envelope/routing-key)
   (message      :type message
                 :initarg :message
                 :reader envelope/message)))

(defmethod print-object ((obj envelope) stream)
  (print-unreadable-safely (channel consumer-tag delivery-tag exchange routing-key) obj stream
    (format stream "CHANNEL ~s CONSUMER-TAG ~s DELIVERY-TAG ~s EXCHANGE ~s ROUTING-KEY ~s"
            channel consumer-tag delivery-tag exchange routing-key)))

(defun fail-if-null (ptr)
  (when (cffi-sys:null-pointer-p ptr)
    (error "Failed"))
  ptr)

(defun verify-status (status)
  (let ((type (cffi:foreign-enum-keyword 'amqp-status-enum status)))
    (unless (eq type :amqp-status-ok)
      (error 'rabbitmq-error :type type))
    type))

(defun verify-rpc-reply (reply)
  (let* ((status (getf reply 'reply-type))
         (type (cffi:foreign-enum-keyword 'amqp-response-type-enum status)))
    (unless (eq type :amqp-response-normal)
      (error 'rabbitmq-server-error :type type))))

(defun verify-rpc-framing-call (state result)
  (when (cffi:null-pointer-p result)
    (verify-rpc-reply (amqp-get-rpc-reply state))))

(defun maybe-release-buffers (conn)
  (amqp-maybe-release-buffers conn))

(defun new-connection ()
  (fail-if-null (amqp-new-connection)))

(defun destroy-connection (state)
  (verify-status (amqp-destroy-connection state)))

(defun tcp-socket-new (connection)
  (fail-if-null (amqp-tcp-socket-new connection)))

(defun socket-open (socket host port)
  (check-type host string)
  (check-type port alexandria:positive-integer)
  (verify-status (amqp-socket-open socket host port)))

(defun login-sasl-plain (state vhost user password &key (channel-max 0) (frame-max 131072) (heartbeat 0) properties)
  (check-type vhost string)
  (check-type user string)
  (check-type password string)
  (with-amqp-table (table properties)
    (cffi:with-foreign-objects ((native-table '(:struct amqp-table-t)))
      (setf (cffi:mem-ref native-table '(:struct amqp-table-t)) table)
      (let ((reply (amqp-login-sasl-plain-with-properties state vhost
                                                          channel-max frame-max heartbeat native-table
                                                          :amqp-sasl-method-plain user password)))
        (unless (= (getf reply 'reply-type) (cffi:foreign-enum-value 'amqp-response-type-enum :amqp-response-normal))
          (error "Illegal response from login"))))))

(defun channel-open (state channel)
  (check-type channel integer)
  (unwind-protect
       (verify-rpc-framing-call state (amqp-channel-open state channel))
    (maybe-release-buffers state)))

(defun channel-flow (state channel active)
  (check-type channel integer)
  (unwind-protect
       (verify-rpc-framing-call state (amqp-channel-flow state channel (if active 1 0)))
    (maybe-release-buffers state)))

(defun channel-close (state channel code)
  (check-type channel integer)
  (check-type code integer)
  (unwind-protect
       (verify-rpc-framing-call state (amqp-channel-close state channel code))
    (maybe-release-buffers state)))

(defun basic-publish (state channel &key exchange routing-key mandatory immediate body)
  (check-type channel integer)
  (check-type exchange (or null string))
  (check-type routing-key (or null string))
  (check-type body (or null array))
  (unwind-protect
       (with-bytes-strings ((exchange-bytes exchange)
                            (routing-key-bytes routing-key))
         (labels ((send (data)
                    (verify-status (amqp-basic-publish state channel exchange-bytes routing-key-bytes
                                                       (if mandatory 1 0) (if immediate 1 0)
                                                       (cffi-sys:null-pointer) data))))
           (if body
               (with-bytes-struct (body-val body)
                 (send body-val))
               ;; ELSE: body is nil, send a blank struct
               (send (list 'len 0 'bytes (cffi-sys:null-pointer))))))
    (maybe-release-buffers state)))

(defun exchange-declare (state channel exchange type &key passive durable arguments)
  (check-type channel integer)
  (check-type exchange string)
  (check-type type string)
  (unwind-protect
       (with-bytes-strings ((exchange-bytes exchange)
                            (type-bytes type))
         (with-amqp-table (table arguments)
           (verify-rpc-framing-call state (amqp-exchange-declare state channel exchange-bytes type-bytes
                                                                 (if passive 1 0) (if durable 1 0) table))))
    (maybe-release-buffers state)))

(defun exchange-delete (state channel exchange &key if-unused)
  (check-type channel integer)
  (check-type exchange string)
  (unwind-protect
       (with-bytes-strings ((exchange-bytes exchange))
         (verify-rpc-framing-call state (amqp-exchange-delete state channel exchange-bytes (if if-unused 1 0))))
    (maybe-release-buffers state)))

(defun exchange-bind (state channel &key destination source routing-key arguments)
  (check-type channel integer)
  (check-type destination (or null string))
  (check-type source (or null string))
  (check-type routing-key (or null string))
  (unwind-protect
       (with-bytes-strings ((destination-bytes destination)
                            (source-bytes source)
                            (routing-key-bytes routing-key))
         (with-amqp-table (table arguments)
           (verify-rpc-framing-call state
                                    (amqp-exchange-bind state channel destination-bytes source-bytes
                                                        routing-key-bytes table))))
    (maybe-release-buffers state)))

(defun exchange-unbind (state channel &key destination source routing-key)
  (check-type channel integer)
  (check-type destination (or null string))
  (check-type source (or null string))
  (check-type routing-key (or null string))
  (with-bytes-strings ((destination-bytes destination)
                       (source-bytes source)
                       (routing-key-bytes routing-key))
    (verify-rpc-framing-call state
                             (amqp-exchange-unbind state channel destination-bytes source-bytes
                                                   routing-key-bytes amqp-empty-table))))

(defun queue-declare (state channel &key queue passive durable exclusive auto-delete arguments)
  (check-type channel integer)
  (check-type queue (or null string))
  (unwind-protect
       (with-bytes-string (queue-bytes queue)
         (with-amqp-table (table arguments)
           (let ((result (amqp-queue-declare state channel queue-bytes (if passive 1 0) (if durable 1 0)
                                             (if exclusive 1 0) (if auto-delete 1 0) table)))
             (verify-rpc-reply (amqp-get-rpc-reply state))
             (values (bytes->string (cffi:foreign-slot-value result
                                                             '(:struct amqp-queue-declare-ok-t)
                                                             'queue))
                     (cffi:foreign-slot-value result '(:struct amqp-queue-declare-ok-t) 'message-count)
                     (cffi:foreign-slot-value result '(:struct amqp-queue-declare-ok-t) 'consumer-count)))))
    (maybe-release-buffers state)))

(defun queue-bind (state channel &key queue exchange routing-key arguments)
  (check-type channel integer)
  (check-type queue (or null string))
  (check-type exchange (or null string))
  (check-type routing-key (or null string))
  (unwind-protect
       (with-bytes-strings ((queue-bytes queue)
                            (exchange-bytes exchange)
                            (routing-key-bytes routing-key))
         (with-amqp-table (table arguments)
           (verify-rpc-framing-call state
                                    (amqp-queue-bind state channel queue-bytes exchange-bytes
                                                     routing-key-bytes table))))
    (maybe-release-buffers state)))

(defun queue-unbind (state channel &key queue exchange routing-key arguments)
  (check-type channel integer)
  (check-type queue (or null string))
  (check-type exchange (or null string))
  (check-type routing-key (or null string))
  (unwind-protect
       (with-bytes-strings ((queue-bytes queue)
                            (exchange-bytes exchange)
                            (routing-key-bytes routing-key))
         (with-amqp-table (table arguments)
           (verify-rpc-framing-call state
                                    (amqp-queue-unbind state channel queue-bytes exchange-bytes
                                                       routing-key-bytes table))
           nil))
    (maybe-release-buffers state)))

(defun basic-consume (state channel queue &key consumer-tag no-local no-ack exclusive arguments)
  (check-type channel integer)
  (check-type queue string)
  (check-type consumer-tag (or null string))
  (unwind-protect
       (with-bytes-strings ((queue-bytes queue)
                            (consumer-tag-bytes consumer-tag))
         (with-amqp-table (table arguments)
           (let ((result (amqp-basic-consume state channel queue-bytes consumer-tag-bytes
                                             (if no-local 1 0) (if no-ack 1 0) (if exclusive 1 0) table)))
             (verify-rpc-reply (amqp-get-rpc-reply state))
             (bytes->string (cffi:foreign-slot-value result '(:struct amqp-basic-consume-ok-t) 'consumer-tag)))))
    (maybe-release-buffers state)))

(defun process-consume-library-error (state)
  (cffi:with-foreign-objects ((foreign-frame '(:struct amqp-frame-t)))
    (verify-status (amqp-simple-wait-frame state foreign-frame))
    (when (= (cffi:foreign-slot-value foreign-frame '(:struct amqp-frame-t) 'frame-type)
             amqp-frame-method)
      (error "Frame errors not currently handled"))))

(defun consume-message (state &key timeout)
  (check-type timeout (or null integer))
  (unwind-protect
       (with-foreign-timeval (native-timeout timeout)
         (cffi:with-foreign-objects ((envelope '(:struct amqp-envelope-t)))
           (let* ((result (amqp-consume-message state envelope native-timeout 0))
                  (status (getf result 'reply-type)))
             (cond ((= status (cffi:foreign-enum-value 'amqp-response-type-enum :amqp-response-normal))
                    (unwind-protect
                         (flet ((getval (slot-name)
                                  (cffi:foreign-slot-value envelope '(:struct amqp-envelope-t) slot-name)))
                           (make-instance 'envelope
                                          :channel (getval 'channel)
                                          :consumer-tag (bytes->string (getval 'consumer-tag))
                                          :delivery-tag (getval 'delivery-tag)
                                          :exchange (bytes->string (getval 'exchange))
                                          :routing-key (bytes->string (getval 'routing-key))
                                          :message (make-envelope-message (getval 'message))))
                      (amqp-destroy-envelope envelope)))

                   ;; Treat library errors
                   ((and (= status (cffi:foreign-enum-value 'amqp-response-type-enum :amqp-response-library-exception))
                         (= (getf result 'library-error)
                            (cffi:foreign-enum-value 'amqp-status-enum :amqp-status-unexpected-state)))
                    (process-consume-library-error state))))))
    (maybe-release-buffers state)))

(defmacro with-connection ((conn) &body body)
  (let ((conn-sym (gensym "CONN-")))
    `(let ((,conn-sym (new-connection)))
       (unwind-protect
            (let ((,conn ,conn-sym))
              ,@body)
         (destroy-connection ,conn-sym)))))
