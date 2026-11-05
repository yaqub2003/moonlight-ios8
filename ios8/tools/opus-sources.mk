# Prints the list of Opus source files (from Opus's own *.mk lists)
include $(OPUS_DIR)/opus_sources.mk
include $(OPUS_DIR)/celt_sources.mk
include $(OPUS_DIR)/silk_sources.mk

print:
	@echo $(OPUS_SOURCES) $(OPUS_SOURCES_FLOAT) $(CELT_SOURCES) $(SILK_SOURCES) $(SILK_SOURCES_FLOAT)
