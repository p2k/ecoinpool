
## Makefile for building the site design document ##

SRC_DIR = src
BUILD_DIR = build
CC_JAR = compiler.jar
SASS = sass
ESCRIPT = escript

TARGET = main_db_site.json

RESOURCES = $(SRC_DIR)/unload.png \
    $(SRC_DIR)/templates.html

SCRIPTS = $(BUILD_DIR)/handlebars.1.0.0.beta.3.js \
	$(BUILD_DIR)/jquery.dialog.js \
	$(BUILD_DIR)/ecoinpool.js \
	$(BUILD_DIR)/home.js \
	$(BUILD_DIR)/subpool.js

STYLES = $(BUILD_DIR)/style.css

LOADERS = $(SRC_DIR)/home.loader.js \
	$(SRC_DIR)/subpool.loader.js


$(BUILD_DIR)/%.js: $(SRC_DIR)/%.js
	@echo "  CLC $<"
	@java -jar $(CC_JAR) --js $< --js_output_file $@

$(BUILD_DIR)/%.css: $(SRC_DIR)/%.scss
	@echo "  SASS $<"
	@$(SASS) --scss --compass $< $@


.PHONY: all

$(TARGET): $(LOADERS) $(SCRIPTS) $(STYLES) $(RESOURCES) site_maker.escript
	@echo "  Writing $@ ..."
	@$(ESCRIPT) site_maker.escript --loaders $(LOADERS) --resources $(SCRIPTS) $(STYLES) $(RESOURCES) --target $@

all: $(TARGET)
