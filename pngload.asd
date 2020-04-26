(asdf:defsystem #:pngload
  :description "A reader for the PNG image format."
  :author ("Michael Fiano <mail@michaelfiano.com>"
           "Bart Botta <00003b@gmail.com>")
  :license "MIT"
  :homepage "https://github.com/HackerTheory/pngload"
  :source-control (:git "https://github.com/HackerTheory/pngload.git")
  :bug-tracker "https://github.com/HackerTheory/pngload/issues"
  :encoding :utf-8
  :depends-on (#:alexandria
               #:3bz
               (:feature (:and (:not :mezzano) (:not :abcl)) #:cffi)
               (:feature (:and (:not :mezzano) (:not :abcl)) #:mmap)
               (:feature (:and (:not :clisp) (:not :abcl)) #:static-vectors)
               #:swap-bytes)
  :pathname "src"
  :serial t
  :components
  ((:file "package")
   (:file "common")
   (:file "source")
   (:file "source-noffi" :if-feature (:or :mezzano :abcl))
   (:file "source-ffi" :if-feature (:and (:not :mezzano) (:not :abcl)))
   (:file "properties")
   (:file "conditions")
   (:file "chunk")
   (:file "chunk-data")
   (:file "datastream")
   (:file "deinterlace")
   (:file "decode")
   (:file "png-nommap" :if-feature (:or :mezzano :abcl))
   (:file "png-mmap" :if-feature (:and (:not :mezzano) (:not :abcl)))
   (:file "png")))
