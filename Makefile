
all: release

release:
	VERSION=`git describe --tags`; \
	git archive --format zip --output "sedimentology-$${VERSION}.zip" --prefix=sedimentology/ master
