
release:
	VERSION=`git describe --tags`; \
	git archive --format zip --output "sedimentology-mt-$${VERSION}.zip" --prefix=sedimentology-mt/ master
