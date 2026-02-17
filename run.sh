docker run -it --rm \
		-v ${PWD}:/workspace/ \
        -v ${HOME}/.config/opencode/:/home/dev/.config/opencode/ \
		-w /workspace/ \
        --network host \
		opencode-fk \
		bash -c "exec bash"