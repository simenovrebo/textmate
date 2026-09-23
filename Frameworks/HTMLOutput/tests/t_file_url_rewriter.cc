#include "../src/helpers/file_url_rewriter.h"

static std::string rewrite (std::string const& str)
{
	file_url_rewriter_t rewriter;
	return rewriter.feed(str, true);
}

void test_url_positions ()
{
	OAK_ASSERT_EQ(rewrite("<link href=\"file:///a.css\">"),         "<link href=\"tm-file:///a.css\">");
	OAK_ASSERT_EQ(rewrite("<img src='file:///a.png'>"),             "<img src='tm-file:///a.png'>");
	OAK_ASSERT_EQ(rewrite("<img src=file:///a.png>"),               "<img src=tm-file:///a.png>");
	OAK_ASSERT_EQ(rewrite("<base href='file:///Users/me/'>"),       "<base href='tm-file:///Users/me/'>");
	OAK_ASSERT_EQ(rewrite("<div style=\"background:url(file:///a.png)\">"), "<div style=\"background:url(tm-file:///a.png)\">");
	OAK_ASSERT_EQ(rewrite("window.location=\"file://\" + page;"),   "window.location=\"tm-file://\" + page;");
	OAK_ASSERT_EQ(rewrite("href=\"file://localhost/a\""),           "href=\"tm-file://localhost/a\"");
}

void test_text_is_unchanged ()
{
	OAK_ASSERT_EQ(rewrite("See file:///etc/hosts for details"),     "See file:///etc/hosts for details");
	OAK_ASSERT_EQ(rewrite("<p>file:///etc/hosts</p>"),              "<p>file:///etc/hosts</p>");
	OAK_ASSERT_EQ(rewrite("\"tm-file:///a\""),                      "\"tm-file:///a\"");
	OAK_ASSERT_EQ(rewrite("\"xfile:///a\""),                        "\"xfile:///a\"");
	OAK_ASSERT_EQ(rewrite("\"file:/a\""),                           "\"file:/a\"");
	OAK_ASSERT_EQ(rewrite(std::string("\0file:///a", 10)),          std::string("\0file:///a", 10));
	OAK_ASSERT_EQ(rewrite(""),                                      "");
}

void test_consecutive_urls ()
{
	OAK_ASSERT_EQ(rewrite("\"file:///a\" 'file:///b' (file:///c)"), "\"tm-file:///a\" 'tm-file:///b' (tm-file:///c)");
	OAK_ASSERT_EQ(rewrite("=file://=file://"),                      "=tm-file://=tm-file://");
}

void test_partial_scheme_at_end ()
{
	file_url_rewriter_t rewriter;
	OAK_ASSERT_EQ(rewriter.feed("<a href=\"fil"), "<a href=\"");
	OAK_ASSERT_EQ(rewriter.feed("e:///x\">"),     "tm-file:///x\">");

	file_url_rewriter_t notAScheme;
	OAK_ASSERT_EQ(notAScheme.feed("\"fil"),       "\"");
	OAK_ASSERT_EQ(notAScheme.feed("m\""),         "film\"");

	file_url_rewriter_t flushed;
	OAK_ASSERT_EQ(flushed.feed("\"file:"),        "\"");
	OAK_ASSERT_EQ(flushed.feed("", 0, true),      "file:");
}

void test_every_split ()
{
	std::string const input    = "<base href='file:///b/'><a href=\"file:///x\">file://y</a><img src='file:///z'><div style=\"background:url(file:///w)\">";
	std::string const expected = "<base href='tm-file:///b/'><a href=\"tm-file:///x\">file://y</a><img src='tm-file:///z'><div style=\"background:url(tm-file:///w)\">";

	for(size_t split1 = 0; split1 <= input.size(); ++split1)
	{
		for(size_t split2 = split1; split2 <= input.size(); ++split2)
		{
			file_url_rewriter_t rewriter;
			std::string res;
			res += rewriter.feed(input.data(), split1);
			res += rewriter.feed(input.data() + split1, split2 - split1);
			res += rewriter.feed(input.data() + split2, input.size() - split2);
			res += rewriter.feed("", 0, true);
			OAK_ASSERT_EQ(res, expected);
		}
	}
}

void test_byte_at_a_time ()
{
	std::string const input = "a='file:///1' b=\"file:///2\" c=file:///3 file:///4";
	file_url_rewriter_t rewriter;
	std::string res;
	for(char ch : input)
		res += rewriter.feed(&ch, 1);
	res += rewriter.feed("", 0, true);
	OAK_ASSERT_EQ(res, "a='tm-file:///1' b=\"tm-file:///2\" c=tm-file:///3 file:///4");
}
