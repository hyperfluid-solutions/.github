FILE?='privacy_no-data.tpl.md'
OUTFILE?='PRIVACY.md'

template:
	(source ./vars.sh; envsubst < $(FILE) > $(OUTFILE);)
	./check.sh $(OUTFILE)
