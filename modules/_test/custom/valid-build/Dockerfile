FROM alpine:3.18

# Test build argument
ARG TEST_ARG=default-value

# Add a test file to verify the build worked
RUN echo "Test build completed with arg: ${TEST_ARG}" > /test-build-info.txt

# Add a simple label for identification
LABEL test.sync-script="true"
LABEL test.build-arg="${TEST_ARG}"

# Default command
CMD ["cat", "/test-build-info.txt"]