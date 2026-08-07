;;; ============================================================
;;; Layer Cycle Manager
;;; File: lcm_loader.lsp
;;; Stage 7: one-time installer
;;; ============================================================

(vl-load-com)


;;; ------------------------------------------------------------
;;; Installer command: LCMINSTALL
;;; ------------------------------------------------------------

(defun C:LCMINSTALL
  (
    /
    file
    path
    cur
    tp
    cuix-path
  )

  (prompt "\n=== Установка Layer Cycle Manager ===")

  ;; ----------------------------------------------------------
  ;; 1. Ask user to point to program folder
  ;; ----------------------------------------------------------

  (setq file
    (getfiled
      "Выберите файл lcm_main.lsp в папке LayerCycleManager"
      ""
      "lsp"
      0
    )
  )

  (if (not file)
    (progn
      (prompt "\nУстановка отменена.")
      (princ)
      (exit)
    )
  )

  (setq path (vl-filename-directory file))

  ;; Normalize slashes
  (setq path (vl-string-translate "\\" "/" path))

  (prompt (strcat "\nПапка программы: " path))


  ;; ----------------------------------------------------------
  ;; 2. Add folder to Support File Search Path
  ;; ----------------------------------------------------------

  (setq cur (getenv "ACAD"))

  (if (not cur)
    (setq cur "")
  )

  (if (not (vl-string-search path cur))
    (progn
      (if (= cur "")
        (setenv "ACAD" path)
        (setenv "ACAD" (strcat cur ";" path))
      )
      (prompt "\nПапка добавлена в Support File Search Path.")
    )
    (prompt "\nПапка уже есть в Support File Search Path.")
  )


  ;; ----------------------------------------------------------
  ;; 3. Add folder to Trusted Locations
  ;; ----------------------------------------------------------

  (setq tp (getvar "TRUSTEDPATHS"))

  (if (not tp)
    (setq tp "")
  )

  (if (not (vl-string-search path tp))
    (progn
      (if (= tp "")
        (setvar "TRUSTEDPATHS" path)
        (setvar "TRUSTEDPATHS" (strcat tp ";" path))
      )
      (prompt "\nПапка добавлена в Trusted Locations.")
    )
    (prompt "\nПапка уже есть в Trusted Locations.")
  )


  ;; ----------------------------------------------------------
  ;; 4. Save path for reference
  ;; ----------------------------------------------------------

  (setenv "LCM_PATH" path)


  ;; ----------------------------------------------------------
  ;; 5. Load program
  ;; ----------------------------------------------------------

  (load (strcat path "/lcm_main.lsp"))


  ;; ----------------------------------------------------------
  ;; 6. Load CUIX interface
  ;; ----------------------------------------------------------

  (setq cuix-path (strcat path "/lcm.cuix"))

  (if (findfile cuix-path)
    (progn
      (command "_menuload" cuix-path "")
      (prompt "\nЗагрузка lcm.cuix выполнена (или файл уже был загружен).")
    )
    (prompt "\nВНИМАНИЕ: файл lcm.cuix не найден в папке программы.")
  )


  ;; ----------------------------------------------------------
  ;; 7. Final message
  ;; ----------------------------------------------------------

  (prompt
    (strcat
      "\nУстановка завершена."
      "\nВ ленте Ribbon должна появиться вкладка Layer Cycle Manager."
      "\nКоманда запуска: LCM"
    )
  )

  (princ)
)


(princ)