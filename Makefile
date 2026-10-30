EMACS ?= emacs
LISPM_KIT ?= ../lispm-kit
LISPM_UI ?= ../lispm-ui
LISPM_AGENT ?= ../lisp_machine/lisp
LOAD_PATH = -L . -L $(LISPM_KIT) -L $(LISPM_UI) -L $(LISPM_AGENT)
FILES = lispm-office-layout.el lispm-office-render.el lispm-office-details.el lispm-office-inspect.el lispm-office-demo.el lispm-office.el lispm-office-plugin.el lispm-office-extension.el

.PHONY: test compile
test:
	$(EMACS) -Q --batch $(LOAD_PATH) --eval '(setq native-comp-enable-subr-trampolines nil)' \
	  --eval '(mapc (lambda (file) (require (intern (file-name-base file)) file)) (directory-files "test" t "-test\\.el$$"))' \
	  -f ert-run-tests-batch-and-exit

compile:
	$(EMACS) -Q --batch $(LOAD_PATH) --eval '(setq byte-compile-error-on-warn t native-comp-enable-subr-trampolines nil)' \
	  -f batch-byte-compile $(FILES); status=$$?; rm -f *.elc; exit $$status
