require File.dirname(__FILE__) + '/../../spec_helper'
require File.dirname(__FILE__) + '/fixtures/classes.rb'

describe "String#rindex with object" do
  it "raises a TypeError if obj isn't a String, Fixnum or Regexp" do
    should_raise(TypeError) { "hello".rindex(:sym) }    
    should_raise(TypeError) { "hello".rindex(Object.new) }
  end

  it "doesn't try to convert obj to an integer via to_int" do
    obj = Object.new
    obj.should_not_receive(:to_int)
    should_raise(TypeError) { "hello".rindex(obj) }
  end

  # Note: MRI doesn't call to_str, but should do so because index() does it.
  # See http://groups.google.com/group/ruby-core-google/t/3f2d4129febd2a66

  noncompliant :rubinius do
    it "tries to convert obj to a string via to_str" do
      obj = Object.new
      def obj.to_str() "lo" end
      "hello".rindex(obj).should == "hello".rindex("lo")

      obj = Object.new
      def obj.respond_to?(arg) true end
      def obj.method_missing(*args) "o" end
      "hello".rindex(obj).should == "hello".rindex("o")
    end
  end
  
  compliant :mri, :jruby do
    version "1.8.6" do
      it "tries to convert obj to a string via to_str" do
        obj = Object.new
        def obj.to_str() "lo" end
        should_raise(Exception) { "hello".rindex(obj) }

        obj = Object.new
        def obj.respond_to?(arg) true end
        def obj.method_missing(*args) "o" end
        should_raise(Exception) { "hello".rindex(obj) }
      end
    end
  end
end

describe "String#rindex with Fixnum" do
  it "returns the index of the last occurrence of the given character" do
    "hello".rindex(?e).should == 1
    "hello".rindex(?l).should == 3
  end
  
  it "doesn't use fixnum % 256" do
    "hello".rindex(?e + 256 * 3).should == nil
    "hello".rindex(-(256 - ?e)).should == nil
  end
  
  it "starts the search at the given offset" do
    "blablabla".rindex(?b, 0).should == 0
    "blablabla".rindex(?b, 1).should == 0
    "blablabla".rindex(?b, 2).should == 0
    "blablabla".rindex(?b, 3).should == 3
    "blablabla".rindex(?b, 4).should == 3
    "blablabla".rindex(?b, 5).should == 3
    "blablabla".rindex(?b, 6).should == 6
    "blablabla".rindex(?b, 7).should == 6
    "blablabla".rindex(?b, 8).should == 6
    "blablabla".rindex(?b, 9).should == 6
    "blablabla".rindex(?b, 10).should == 6

    "blablabla".rindex(?a, 2).should == 2
    "blablabla".rindex(?a, 3).should == 2
    "blablabla".rindex(?a, 4).should == 2
    "blablabla".rindex(?a, 5).should == 5
    "blablabla".rindex(?a, 6).should == 5
    "blablabla".rindex(?a, 7).should == 5
    "blablabla".rindex(?a, 8).should == 8
    "blablabla".rindex(?a, 9).should == 8
    "blablabla".rindex(?a, 10).should == 8
  end
  
  it "starts the search at offset + self.length if offset is negative" do
    str = "blablabla"
    
    [?a, ?b].each do |needle|
      (-str.length .. -1).each do |offset|
        str.rindex(needle, offset).should ==
        str.rindex(needle, offset + str.length)
      end
    end
  end
  
  it "returns nil if the character isn't found" do
    "hello".rindex(0).should == nil
    
    "hello".rindex(?H).should == nil
    "hello".rindex(?z).should == nil
    "hello".rindex(?o, 2).should == nil
    
    "blablabla".rindex(?a, 0).should == nil
    "blablabla".rindex(?a, 1).should == nil
    
    "blablabla".rindex(?a, -8).should == nil
    "blablabla".rindex(?a, -9).should == nil
    
    "blablabla".rindex(?b, -10).should == nil
    "blablabla".rindex(?b, -20).should == nil
  end
  
  it "tries to convert start_offset to an integer via to_int" do
    obj = Object.new
    def obj.to_int() 5 end
    "str".rindex(?s, obj).should == 0
    
    obj = Object.new
    def obj.respond_to?(arg) true end
    def obj.method_missing(*args); 5; end
    "str".rindex(?s, obj).should == 0
  end
  
  it "raises a TypeError when given offset is nil" do
    should_raise(TypeError) do
      "str".rindex(?s, nil)
    end
    
    should_raise(TypeError) do
      "str".rindex(?t, nil)
    end
  end
end

describe "String#rindex with String" do
  it "behaves the same as String#rindex(char) for one-character strings" do
    ["blablabla", "hello cruel world...!"].each do |str|
      str.split("").uniq.each do |str|
        chr = str[0]
        str.rindex(str).should == str.rindex(chr)
        
        0.upto(str.size + 1) do |start|
          str.rindex(str, start).should == str.rindex(chr, start)
        end
        
        (-str.size - 1).upto(-1) do |start|
          str.rindex(str, start).should == str.rindex(chr, start)
        end
      end
    end
  end
  
  it "returns the index of the last occurrence of the given substring" do
    "blablabla".rindex("").should == 9
    "blablabla".rindex("a").should == 8
    "blablabla".rindex("la").should == 7
    "blablabla".rindex("bla").should == 6
    "blablabla".rindex("abla").should == 5
    "blablabla".rindex("labla").should == 4
    "blablabla".rindex("blabla").should == 3
    "blablabla".rindex("ablabla").should == 2
    "blablabla".rindex("lablabla").should == 1
    "blablabla".rindex("blablabla").should == 0
    
    "blablabla".rindex("l").should == 7
    "blablabla".rindex("bl").should == 6
    "blablabla".rindex("abl").should == 5
    "blablabla".rindex("labl").should == 4
    "blablabla".rindex("blabl").should == 3
    "blablabla".rindex("ablabl").should == 2
    "blablabla".rindex("lablabl").should == 1
    "blablabla".rindex("blablabl").should == 0

    "blablabla".rindex("b").should == 6
    "blablabla".rindex("ab").should == 5
    "blablabla".rindex("lab").should == 4
    "blablabla".rindex("blab").should == 3
    "blablabla".rindex("ablab").should == 2
    "blablabla".rindex("lablab").should == 1
    "blablabla".rindex("blablab").should == 0
  end  
  
  it "doesn't set $~" do
    $~ = nil
    
    'hello.'.rindex('ll')
    $~.should == nil
  end
  
  it "ignores string subclasses" do
    "blablabla".rindex(MyString.new("bla")).should == 6
    MyString.new("blablabla").rindex("bla").should == 6
    MyString.new("blablabla").rindex(MyString.new("bla")).should == 6
  end
  
  it "starts the search at the given offset" do
    "blablabla".rindex("bl", 0).should == 0
    "blablabla".rindex("bl", 1).should == 0
    "blablabla".rindex("bl", 2).should == 0
    "blablabla".rindex("bl", 3).should == 3

    "blablabla".rindex("bla", 0).should == 0
    "blablabla".rindex("bla", 1).should == 0
    "blablabla".rindex("bla", 2).should == 0
    "blablabla".rindex("bla", 3).should == 3

    "blablabla".rindex("blab", 0).should == 0
    "blablabla".rindex("blab", 1).should == 0
    "blablabla".rindex("blab", 2).should == 0
    "blablabla".rindex("blab", 3).should == 3
    "blablabla".rindex("blab", 6).should == 3
    "blablablax".rindex("blab", 6).should == 3

    "blablabla".rindex("la", 1).should == 1
    "blablabla".rindex("la", 2).should == 1
    "blablabla".rindex("la", 3).should == 1
    "blablabla".rindex("la", 4).should == 4

    "blablabla".rindex("lab", 1).should == 1
    "blablabla".rindex("lab", 2).should == 1
    "blablabla".rindex("lab", 3).should == 1
    "blablabla".rindex("lab", 4).should == 4

    "blablabla".rindex("ab", 2).should == 2
    "blablabla".rindex("ab", 3).should == 2
    "blablabla".rindex("ab", 4).should == 2
    "blablabla".rindex("ab", 5).should == 5
    
    "blablabla".rindex("", 0).should == 0
    "blablabla".rindex("", 1).should == 1
    "blablabla".rindex("", 2).should == 2
    "blablabla".rindex("", 7).should == 7
    "blablabla".rindex("", 8).should == 8
    "blablabla".rindex("", 9).should == 9
    "blablabla".rindex("", 10).should == 9
  end
  
  it "starts the search at offset + self.length if offset is negative" do
    str = "blablabla"
    
    ["bl", "bla", "blab", "la", "lab", "ab", ""].each do |needle|
      (-str.length .. -1).each do |offset|
        str.rindex(needle, offset).should ==
        str.rindex(needle, offset + str.length)
      end
    end
  end

  it "returns nil if the substring isn't found" do
    "blablabla".rindex("B").should == nil
    "blablabla".rindex("z").should == nil
    "blablabla".rindex("BLA").should == nil
    "blablabla".rindex("blablablabla").should == nil
        
    "hello".rindex("lo", 0).should == nil
    "hello".rindex("lo", 1).should == nil
    "hello".rindex("lo", 2).should == nil

    "hello".rindex("llo", 0).should == nil
    "hello".rindex("llo", 1).should == nil

    "hello".rindex("el", 0).should == nil
    "hello".rindex("ello", 0).should == nil
    
    "hello".rindex("", -6).should == nil
    "hello".rindex("", -7).should == nil

    "hello".rindex("h", -6).should == nil
  end
  
  it "tries to convert start_offset to an integer via to_int" do
    obj = Object.new
    def obj.to_int() 5 end
    "str".rindex("st", obj).should == 0
    
    obj = Object.new
    def obj.respond_to?(arg) true end
    def obj.method_missing(*args) 5 end
    "str".rindex("st", obj).should == 0
  end

  it "raises a TypeError when given offset is nil" do
    should_raise(TypeError) do
      "str".rindex("st", nil)
    end
  end
end

describe "String#rindex with Regexp" do
  it "behaves the same as String#rindex(string) for escaped string regexps" do
    ["blablabla", "hello cruel world...!"].each do |str|
      ["", "b", "bla", "lab", "o c", "d."].each do |needle|
        regexp = Regexp.new(Regexp.escape(needle))
        str.rindex(regexp).should == str.rindex(needle)
        
        0.upto(str.size + 1) do |start|
          str.rindex(regexp, start).should == str.rindex(needle, start)
        end
        
        (-str.size - 1).upto(-1) do |start|
          str.rindex(regexp, start).should == str.rindex(needle, start)
        end
      end
    end
  end
  
  it "returns the index of the first match from the end of string of regexp" do
    "blablabla".rindex(/bla/).should == 6
    "blablabla".rindex(/BLA/i).should == 6

    "blablabla".rindex(/.{0}/).should == 9
    "blablabla".rindex(/.{1}/).should == 8
    "blablabla".rindex(/.{2}/).should == 7
    "blablabla".rindex(/.{6}/).should == 3
    "blablabla".rindex(/.{9}/).should == 0

    "blablabla".rindex(/.*/).should == 9
    "blablabla".rindex(/.+/).should == 8

    "blablabla".rindex(/bla|a/).should == 8
    
    "blablabla".rindex(/\A/).should == 0
    "blablabla".rindex(/\Z/).should == 9
    "blablabla".rindex(/\z/).should == 9
    "blablabla\n".rindex(/\Z/).should == 10
    "blablabla\n".rindex(/\z/).should == 10

    "blablabla".rindex(/^/).should == 0
    "\nblablabla".rindex(/^/).should == 1
    "b\nlablabla".rindex(/^/).should == 2
    "blablabla".rindex(/$/).should == 9
    
    "blablabla".rindex(/.l./).should == 6
  end
  
  it "sets $~ to MatchData of match and nil when there's none" do
    'hello.'.rindex(/.(.)/)
    $~[0].should == 'o.'

    'hello.'.rindex(/not/)
    $~.should == nil
  end
  
  it "starts the search at the given offset" do
    "blablabla".rindex(/.{0}/, 5).should == 5
    "blablabla".rindex(/.{1}/, 5).should == 5
    "blablabla".rindex(/.{2}/, 5).should == 5
    "blablabla".rindex(/.{3}/, 5).should == 5
    "blablabla".rindex(/.{4}/, 5).should == 5

    "blablabla".rindex(/.{0}/, 3).should == 3
    "blablabla".rindex(/.{1}/, 3).should == 3
    "blablabla".rindex(/.{2}/, 3).should == 3
    "blablabla".rindex(/.{5}/, 3).should == 3
    "blablabla".rindex(/.{6}/, 3).should == 3

    "blablabla".rindex(/.l./, 0).should == 0
    "blablabla".rindex(/.l./, 1).should == 0
    "blablabla".rindex(/.l./, 2).should == 0
    "blablabla".rindex(/.l./, 3).should == 3
    
    "blablablax".rindex(/.x/, 10).should == 8
    "blablablax".rindex(/.x/, 9).should == 8
    "blablablax".rindex(/.x/, 8).should == 8

    "blablablax".rindex(/..x/, 10).should == 7
    "blablablax".rindex(/..x/, 9).should == 7
    "blablablax".rindex(/..x/, 8).should == 7
    "blablablax".rindex(/..x/, 7).should == 7
    
    "blablabla\n".rindex(/\Z/, 9).should == 9
  end
  
  it "starts the search at offset + self.length if offset is negative" do
    str = "blablabla"
    
    ["bl", "bla", "blab", "la", "lab", "ab", ""].each do |needle|
      (-str.length .. -1).each do |offset|
        str.rindex(needle, offset).should ==
        str.rindex(needle, offset + str.length)
      end
    end
  end

  it "returns nil if the substring isn't found" do
    "blablabla".rindex(/BLA/).should == nil
    "blablabla".rindex(/.{10}/).should == nil
    "blablablax".rindex(/.x/, 7).should == nil
    "blablablax".rindex(/..x/, 6).should == nil
    
    "blablabla".rindex(/\Z/, 5).should == nil
    "blablabla".rindex(/\z/, 5).should == nil
    "blablabla\n".rindex(/\z/, 9).should == nil
  end

  it "supports \\G which matches at the given start offset" do
    "helloYOU.".rindex(/YOU\G/, 8).should == 5
    "helloYOU.".rindex(/YOU\G/).should == nil

    idx = "helloYOUall!".index("YOU")
    re = /YOU.+\G.+/
    # The # marks where \G will match.
    [
      ["helloYOU#all.", nil],
      ["helloYOUa#ll.", idx],
      ["helloYOUal#l.", idx],
      ["helloYOUall#.", idx],
      ["helloYOUall.#", nil]
    ].each do |i|
      start = i[0].index("#")
      str = i[0].delete("#")

      str.rindex(re, start).should == i[1]
    end
  end
  
  it "tries to convert start_offset to an integer via to_int" do
    obj = Object.new
    def obj.to_int() 5 end
    "str".rindex(/../, obj).should == 1
    
    obj = Object.new
    def obj.respond_to?(arg) true end
    def obj.method_missing(*args); 5; end
    "str".rindex(/../, obj).should == 1
  end

  it "raises a TypeError when given offset is nil" do
    should_raise(TypeError) do
      "str".rindex(/../, nil)
    end
  end
end
