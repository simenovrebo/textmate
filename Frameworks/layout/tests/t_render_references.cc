// Temporary harness (not committed): draws files with TextMate’s layout for TextMateSwiftUI’s reference images.
// RENDER_MANIFEST is a file with lines “path|scope|tabSize|softTabs|softWrap”, RENDER_OUT the folder for the PNGs.
#include <layout/layout.h>
#include <bundles/bundles.h>
#include <bundles/load.h>
#include <plist/fs_cache.h>
#include <theme/theme.h>
#include <io/path.h>
#include <text/tokenize.h>
#include <ImageIO/ImageIO.h>
#include <CoreServices/CoreServices.h>

static void write_png (CGImageRef image, std::string const& path)
{
	CFURLRef url = CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault, (UInt8 const*)path.data(), path.size(), false);
	CGImageDestinationRef dest = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, nullptr);
	CGImageDestinationAddImage(dest, image, nullptr);
	CGImageDestinationFinalize(dest);
	CFRelease(dest);
	CFRelease(url);
}

void test_render_references ()
{
	char const* manifest = getenv("RENDER_MANIFEST");
	char const* out = getenv("RENDER_OUT");
	if(!manifest || !out)
		return;

	std::string const support = path::join(path::home(), "Library/Application Support");
	plist::cache_t cache;
	auto index = create_bundle_index({ path::join(support, "TextMate/Bundles"), path::join(support, "TextMate/Managed/Bundles") }, cache);
	bundles::set_index(index.first, index.second);

	std::vector<std::pair<std::string, std::string>> const themes = {
		{ "MacClassic", "71D40D9D-AE48-11D9-920A-000D93589AF6" },
		{ "Twilight",   "766026CB-703D-4610-B070-8DE07D967C5F" },
	};

	std::string const lines = path::content(manifest);
	for(auto const& line : text::tokenize(lines.begin(), lines.end(), '\n'))
	{
		std::vector<std::string> fields;
		for(auto const& field : text::tokenize(line.begin(), line.end(), '|'))
			fields.push_back(field);
		if(fields.size() != 5)
			continue;

		std::string const content = path::content(fields[0]);
		for(auto const& theme : themes)
		{
			ng::buffer_t buffer;
			buffer.insert(0, content);
			buffer.indent().set_tab_size(std::stoi(fields[2]));
			buffer.indent().set_soft_tabs(fields[3] == "1");
			auto grammars = bundles::query(bundles::kFieldGrammarScope, fields[1], scope::wildcard, bundles::kItemTypeGrammar);
			if(!grammars.empty())
				buffer.set_grammar(grammars.front());
			buffer.wait_for_repair();

			ng::layout_t layout(buffer, parse_theme(bundles::lookup(oak::uuid_t(theme.second))), "Menlo-Regular", 12, fields[4] == "1");
			layout.set_viewport_size(CGSizeMake(700, 100));
			for(CGFloat laidOut = 0; laidOut != layout.height(); ) // heights of lines not laid out are estimates
			{
				laidOut = layout.height();
				layout.update_metrics(CGRectMake(0, 0, 700, laidOut));
			}
			CGFloat const height = ceil(layout.height());
			layout.set_viewport_size(CGSizeMake(700, height));

			CGFloat const scale = 2;
			CGColorSpaceRef sRGB = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
			CGContextRef context = CGBitmapContextCreate(nullptr, 700 * scale, height * scale, 8, 0, sRGB, (uint32_t)kCGImageAlphaPremultipliedFirst | (uint32_t)kCGBitmapByteOrder32Little);
			CGContextScaleCTM(context, scale, scale);
			CGContextTranslateCTM(context, 0, height);
			CGContextScaleCTM(context, 1, -1);
			layout.draw(ng::context_t(context, NULL_STR, nullptr), CGRectMake(0, 0, 700, height), true, ng::ranges_t(0));

			CGImageRef image = CGBitmapContextCreateImage(context);
			write_png(image, path::join(out, path::name(fields[0]) + "-" + theme.first + ".png"));
			CGImageRelease(image);
			CGContextRelease(context);
			CGColorSpaceRelease(sRGB);
		}
	}
}
