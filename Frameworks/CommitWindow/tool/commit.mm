#include <CommitWindow/CommitWindow.h>
#include <oak/ipc.h>
#include <oak/oak.h>

static double const AppVersion = 1.2;

int main (int argc, char* argv[])
{
	if(argc == 2 && (strcmp(argv[1], "-v") == 0 || strcmp(argv[1], "--version") == 0))
	{
		fprintf(stderr, "%1$s %2$.1f (" __DATE__ ")\n", getprogname(), AppVersion);
		return EX_OK;
	}

	@autoreleasepool {
		char const* pid = getenv("TM_PID");
		if(!pid)
		{
			fprintf(stderr, "%s: TM_PID is not set, this tool must be run by TextMate\n", getprogname());
			return EX_USAGE;
		}

		std::string const socketPath = oak::ipc::socket_path(kOakCommitWindowSocketName, atoi(pid));
		int fd = oak::ipc::connect(socketPath);
		if(fd == -1)
		{
			fprintf(stderr, "%s: failed connecting to ‘%s’: %s\n", getprogname(), socketPath.c_str(), strerror(errno));
			return EX_UNAVAILABLE;
		}

		NSMutableArray* arg = [NSMutableArray array];
		for(size_t i = 0; i < argc; ++i)
			[arg addObject:@(argv[i])];

		NSDictionary* request = @{
			kOakCommitWindowArguments:   arg,
			kOakCommitWindowEnvironment: [[NSProcessInfo processInfo] environment],
		};

		NSData* data = [NSPropertyListSerialization dataWithPropertyList:request format:NSPropertyListBinaryFormat_v1_0 options:0 error:nullptr];
		std::string reply;
		if(!data || !oak::ipc::send_message(fd, std::string((char const*)data.bytes, data.length)) || !oak::ipc::receive_message(fd, &reply))
		{
			fprintf(stderr, "%s: no reply from TextMate\n", getprogname());
			return EX_UNAVAILABLE;
		}
		close(fd);

		NSDictionary* options = [NSPropertyListSerialization propertyListWithData:[NSData dataWithBytes:reply.data() length:reply.size()] options:NSPropertyListImmutable format:nullptr error:nullptr];
		if(![options isKindOfClass:[NSDictionary class]])
		{
			fprintf(stderr, "%s: invalid reply from TextMate\n", getprogname());
			return EX_PROTOCOL;
		}

		if(NSString* err = options[kOakCommitWindowStandardError])
			fprintf(stderr, "%s", [err UTF8String]);

		if(NSString* out = options[kOakCommitWindowStandardOutput])
		{
			fprintf(stdout, "%s", [out UTF8String]);

			if([options[kOakCommitWindowContinue] boolValue])
				fprintf(stdout, "TM_SCM_COMMIT_CONTINUE=1\n");
		}

		return [options[kOakCommitWindowReturnCode] intValue];
	}
}
