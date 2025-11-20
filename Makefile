# Define the output parameters file
PARAMS_FILE = parameters.json

# Define input configuration files
WIREGUARD_CONFIG = template_files/wg.conf
CLOUDWATCH_CONFIG = template_files/cloudwatch-config.json
NFTABLES_CONFIG = template_files/nftables.conf

CONFIGS =  $(WIREGUARD_CONFIG) $(CLOUDWATCH_CONFIG) $(NFTABLES_CONFIG)
TEMPLATES += $(patsubst %, %.template, ${CONFIGS})
# Rule to build the parameters file
all: $(TEMPLATES)

# Rule to convert CONFIG to TEMPLATE
%.template: %
	@echo "Creating $@ from $<"
	@cat $< | sed -e 's/"/\\"/g; s/^/"/g; $ ! s/$/\\n",/; $ s/$/\\n"/' > $@


# Clean up the generated parameters file
clean:
	rm -f $(TEMPLATES)
