(asdf:defsystem #:pngload
  :description "A reader for the PNG image format."
  :author ("Michael Fiano <mail@mfiano.net>"
           "Bart Botta <00003b@gmail.com>")
  :license "MIT"
  :homepage "https://github.com/bufferswap/pngload"
  :version "0.1.0"
  :encoding :utf-8
  :defsystem-depends-on (:trivial-features)
  :depends-on
  (#:3bz
   #:alexandria
   (:feature (:and (:not :mezzano) (:not :abcl)) #:cffi)
   (:feature (:and (:not :mezzano) (:not :abcl)) #:mmap)
   #:parse-float
   (:feature (:and (:not :clisp) (:not :abcl)) #:static-vectors)
   #:swap-bytes
   #:uiop
   #:zpb-exif)
  :pathname "src"
  :serial t
  :components
  ((:file "package")
   (:file "common")
   (:file "source")
   (:file "source-noffi" :if-feature (:or :mezzano :abcl))
   (:file "source-ffi" :if-feature (:and (:not :mezzano) (:not :abcl)))
   (:file "properties")
   (:file "chunk")
   (:file "chunk-types")
   (:file "conditions")
   (:file "datastream")
   (:file "deinterlace")
   (:file "decode")
   (:file "metadata")
   (:file "png")
   (:file "octet-vector")
   ;; mmap is supported on windows, but causes issues with long files
   ;; names. I'm not an expert, so just getting rid of it completely
   ;; instead, just for my purposes.
   (:file "png-nommap" :if-feature (:or :mezzano :abcl :windows))
   (:file "png-mmap" :if-feature (:and (:not :mezzano) (:not :abcl) (:not :windows)))))
