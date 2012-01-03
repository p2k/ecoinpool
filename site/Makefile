
## Makefile for building the site design documents ##

SRC_DIR = src
BUILD_DIR = build
CC_JAR = compiler.jar
SASS = sass
ESCRIPT = escript
COPY = cp

ECOINPOOL_TARGET = ecoinpool_site.json
ECOINPOOL_INSTALL_PATH = ../apps/ecoinpool/priv/main_db_site.json

ECOINPOOL_RESOURCES = $(SRC_DIR)/unload.png \
    $(SRC_DIR)/ecoinpool/templates.html

ECOINPOOL_SCRIPTS = $(BUILD_DIR)/handlebars.1.0.0.beta.3.js \
	$(BUILD_DIR)/sha1.js \
	$(BUILD_DIR)/jquery.js \
	$(BUILD_DIR)/jquery.couch.js \
	$(BUILD_DIR)/jquery.dialog.js \
	$(BUILD_DIR)/common.js \
	$(BUILD_DIR)/ecoinpool/home.js \
	$(BUILD_DIR)/ecoinpool/subpool.js

ECOINPOOL_STYLES = $(BUILD_DIR)/style.css

ECOINPOOL_LOADERS = $(SRC_DIR)/ecoinpool/home.loader.js \
	$(SRC_DIR)/ecoinpool/subpool.loader.js


EBITCOIN_TARGET = ebitcoin_site.json
EBITCOIN_INSTALL_PATH = ../apps/ebitcoin/priv/main_db_site.json

EBITCOIN_RESOURCES = $(SRC_DIR)/unload.png \
    $(SRC_DIR)/ebitcoin/templates.html

EBITCOIN_SCRIPTS = $(BUILD_DIR)/handlebars.1.0.0.beta.3.js \
	$(BUILD_DIR)/sha1.js \
	$(BUILD_DIR)/jquery.js \
	$(BUILD_DIR)/jquery.couch.js \
	$(BUILD_DIR)/jquery.dialog.js \
	$(BUILD_DIR)/common.js \
	$(BUILD_DIR)/ebitcoin/home.js \
	$(BUILD_DIR)/ebitcoin/client.js

EBITCOIN_STYLES = $(BUILD_DIR)/style.css

EBITCOIN_LOADERS = $(SRC_DIR)/ebitcoin/home.loader.js \
	$(SRC_DIR)/ebitcoin/client.loader.js


$(BUILD_DIR)/%.js: $(SRC_DIR)/%.js
	@echo "  CLC $<"
	@mkdir -p `dirname $@`
	@java -jar $(CC_JAR) --js $< --js_output_file $@

$(BUILD_DIR)/%.css: $(SRC_DIR)/%.scss
	@echo "  SASS $<"
	@$(SASS) --scss --compass $< $@


.PHONY: all install

all: $(ECOINPOOL_TARGET) $(EBITCOIN_TARGET)

$(ECOINPOOL_TARGET): $(ECOINPOOL_LOADERS) $(ECOINPOOL_SCRIPTS) $(ECOINPOOL_STYLES) $(ECOINPOOL_RESOURCES) site_maker.escript
	@echo "  Writing $@ ..."
	@$(ESCRIPT) site_maker.escript --loaders $(ECOINPOOL_LOADERS) --resources $(ECOINPOOL_SCRIPTS) $(ECOINPOOL_STYLES) $(ECOINPOOL_RESOURCES) --target $@

$(EBITCOIN_TARGET): $(EBITCOIN_LOADERS) $(EBITCOIN_SCRIPTS) $(EBITCOIN_STYLES) $(EBITCOIN_RESOURCES) site_maker.escript
	@echo "  Writing $@ ..."
	@$(ESCRIPT) site_maker.escript --loaders $(EBITCOIN_LOADERS) --resources $(EBITCOIN_SCRIPTS) $(EBITCOIN_STYLES) $(EBITCOIN_RESOURCES) --target $@

install: $(ECOINPOOL_TARGET) $(EBITCOIN_TARGET)
	$(COPY) $(ECOINPOOL_TARGET) $(ECOINPOOL_INSTALL_PATH)
	$(COPY) $(EBITCOIN_TARGET) $(EBITCOIN_INSTALL_PATH)
