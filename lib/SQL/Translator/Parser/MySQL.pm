package SQL::Translator::Parser::MySQL;

# -------------------------------------------------------------------
# $Id: MySQL.pm,v 1.57 2007-02-19 23:35:27 duality72 Exp $
# -------------------------------------------------------------------
# Copyright (C) 2002-4 SQLFairy Authors
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation; version 2.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
# 02111-1307  USA
# -------------------------------------------------------------------

=head1 NAME

SQL::Translator::Parser::MySQL - parser for MySQL

=head1 SYNOPSIS

  use SQL::Translator;
  use SQL::Translator::Parser::MySQL;

  my $translator = SQL::Translator->new;
  $translator->parser("SQL::Translator::Parser::MySQL");

=head1 DESCRIPTION

The grammar is influenced heavily by Tim Bunce's "mysql2ora" grammar.

Here's the word from the MySQL site
(http://www.mysql.com/doc/en/CREATE_TABLE.html):

  CREATE [TEMPORARY] TABLE [IF NOT EXISTS] tbl_name [(create_definition,...)]
  [table_options] [select_statement]
  
  or
  
  CREATE [TEMPORARY] TABLE [IF NOT EXISTS] tbl_name LIKE old_table_name;
  
  create_definition:
    col_name type [NOT NULL | NULL] [DEFAULT default_value] [AUTO_INCREMENT]
              [PRIMARY KEY] [reference_definition]
    or    PRIMARY KEY (index_col_name,...)
    or    KEY [index_name] (index_col_name,...)
    or    INDEX [index_name] (index_col_name,...)
    or    UNIQUE [INDEX] [index_name] (index_col_name,...)
    or    FULLTEXT [INDEX] [index_name] (index_col_name,...)
    or    [CONSTRAINT symbol] FOREIGN KEY [index_name] (index_col_name,...)
              [reference_definition]
    or    CHECK (expr)
  
  type:
          TINYINT[(length)] [UNSIGNED] [ZEROFILL]
    or    SMALLINT[(length)] [UNSIGNED] [ZEROFILL]
    or    MEDIUMINT[(length)] [UNSIGNED] [ZEROFILL]
    or    INT[(length)] [UNSIGNED] [ZEROFILL]
    or    INTEGER[(length)] [UNSIGNED] [ZEROFILL]
    or    BIGINT[(length)] [UNSIGNED] [ZEROFILL]
    or    REAL[(length,decimals)] [UNSIGNED] [ZEROFILL]
    or    DOUBLE[(length,decimals)] [UNSIGNED] [ZEROFILL]
    or    FLOAT[(length,decimals)] [UNSIGNED] [ZEROFILL]
    or    DECIMAL(length,decimals) [UNSIGNED] [ZEROFILL]
    or    NUMERIC(length,decimals) [UNSIGNED] [ZEROFILL]
    or    CHAR(length) [BINARY]
    or    VARCHAR(length) [BINARY]
    or    DATE
    or    TIME
    or    TIMESTAMP
    or    DATETIME
    or    TINYBLOB
    or    BLOB
    or    MEDIUMBLOB
    or    LONGBLOB
    or    TINYTEXT
    or    TEXT
    or    MEDIUMTEXT
    or    LONGTEXT
    or    ENUM(value1,value2,value3,...)
    or    SET(value1,value2,value3,...)
  
  index_col_name:
          col_name [(length)]
  
  reference_definition:
          REFERENCES tbl_name [(index_col_name,...)]
                     [MATCH FULL | MATCH PARTIAL]
                     [ON DELETE reference_option]
                     [ON UPDATE reference_option]
  
  reference_option:
          RESTRICT | CASCADE | SET NULL | NO ACTION | SET DEFAULT
  
  table_options:
          TYPE = {BDB | HEAP | ISAM | InnoDB | MERGE | MRG_MYISAM | MYISAM }
  or      AUTO_INCREMENT = #
  or      AVG_ROW_LENGTH = #
  or      CHECKSUM = {0 | 1}
  or      COMMENT = "string"
  or      MAX_ROWS = #
  or      MIN_ROWS = #
  or      PACK_KEYS = {0 | 1 | DEFAULT}
  or      PASSWORD = "string"
  or      DELAY_KEY_WRITE = {0 | 1}
  or      ROW_FORMAT= { default | dynamic | fixed | compressed }
  or      RAID_TYPE= {1 | STRIPED | RAID0 } RAID_CHUNKS=#  RAID_CHUNKSIZE=#
  or      UNION = (table_name,[table_name...])
  or      INSERT_METHOD= {NO | FIRST | LAST }
  or      DATA DIRECTORY="absolute path to directory"
  or      INDEX DIRECTORY="absolute path to directory"

A subset of the ALTER TABLE syntax that allows addition of foreign keys:

  ALTER [IGNORE] TABLE tbl_name alter_specification [, alter_specification] ...

  alter_specification:
          ADD [CONSTRAINT [symbol]]
          FOREIGN KEY [index_name] (index_col_name,...)
             [reference_definition]

A subset of INSERT that we ignore:

  INSERT anything

=cut

use strict;
use vars qw[ $DEBUG $VERSION $GRAMMAR @EXPORT_OK ];
$VERSION = sprintf "%d.%02d", q$Revision: 1.57 $ =~ /(\d+)\.(\d+)/;
$DEBUG   = 0 unless defined $DEBUG;

use Data::Dumper;
use Parse::RecDescent;
use Exporter;
use base qw(Exporter);

@EXPORT_OK = qw(parse);

# Enable warnings within the Parse::RecDescent module.
$::RD_ERRORS = 1; # Make sure the parser dies when it encounters an error
$::RD_WARN   = 1; # Enable warnings. This will warn on unused rules &c.
$::RD_HINT   = 1; # Give out hints to help fix problems.

$GRAMMAR = << 'END_OF_GRAMMAR';

{ 
    my ( $database_name, %tables, $table_order, @table_comments );
    my $delimiter = ';';
}

#
# The "eofile" rule makes the parser fail if any "statement" rule
# fails.  Otherwise, the first successful match by a "statement" 
# won't cause the failure needed to know that the parse, as a whole,
# failed. -ky
#
startrule : statement(s) eofile { 
    { tables => \%tables, database_name => $database_name } 
}

eofile : /^\Z/

statement : comment
    | use
    | set
    | drop
    | create
    | alter
    | insert
    | delimiter
    | empty_statement
    | <error>

use : /use/i WORD "$delimiter"
    {
        $database_name = $item[2];
        @table_comments = ();
    }

set : /set/i /[^;]+/ "$delimiter"
    { @table_comments = () }

drop : /drop/i TABLE /[^;]+/ "$delimiter"

drop : /drop/i WORD(s) "$delimiter"
    { @table_comments = () }

string :
  # MySQL strings, unlike common SQL strings, can be double-quoted or 
  # single-quoted, and you can escape the delmiters by doubling (but only the 
  # delimiter) or by backslashing.

   /'(\\.|''|[^\\\'])*'/ |
   /"(\\.|""|[^\\\"])*"/
  # For reference, std sql str: /(?:(?:\')(?:[^\']*(?:(?:\'\')[^\']*)*)(?:\'))//

nonstring : /[^;\'"]+/

statement_body : (string | nonstring)(s?)

insert : /insert/i  statement_body "$delimiter"

delimiter : /delimiter/i /[\S]+/
	{ $delimiter = $item[2] }

empty_statement : "$delimiter"

alter : ALTER TABLE table_name alter_specification(s /,/) "$delimiter"
    {
        my $table_name                       = $item{'table_name'};
    die "Cannot ALTER table '$table_name'; it does not exist"
        unless $tables{ $table_name };
        for my $definition ( @{ $item[4] } ) { 
        $definition->{'extra'}->{'alter'} = 1;
        push @{ $tables{ $table_name }{'constraints'} }, $definition;
    }
    }

alter_specification : ADD foreign_key_def
    { $return = $item[2] }

create : CREATE /database/i WORD "$delimiter"
    { @table_comments = () }

create : CREATE TEMPORARY(?) TABLE opt_if_not_exists(?) table_name '(' create_definition(s /,/) /(,\s*)?\)/ table_option(s?) "$delimiter"
    { 
        my $table_name                       = $item{'table_name'};
        $tables{ $table_name }{'order'}      = ++$table_order;
        $tables{ $table_name }{'table_name'} = $table_name;

        if ( @table_comments ) {
            $tables{ $table_name }{'comments'} = [ @table_comments ];
            @table_comments = ();
        }

        my $i = 1;
        for my $definition ( @{ $item[7] } ) {
            if ( $definition->{'supertype'} eq 'field' ) {
                my $field_name = $definition->{'name'};
                $tables{ $table_name }{'fields'}{ $field_name } = 
                    { %$definition, order => $i };
                $i++;
        
                if ( $definition->{'is_primary_key'} ) {
                    push @{ $tables{ $table_name }{'constraints'} },
                        {
                            type   => 'primary_key',
                            fields => [ $field_name ],
                        }
                    ;
                }
            }
            elsif ( $definition->{'supertype'} eq 'constraint' ) {
                push @{ $tables{ $table_name }{'constraints'} }, $definition;
            }
            elsif ( $definition->{'supertype'} eq 'index' ) {
                push @{ $tables{ $table_name }{'indices'} }, $definition;
            }
        }

        if ( my @options = @{ $item{'table_option(s?)'} } ) {
            for my $option ( @options ) {
                my ( $key, $value ) = each %$option;
                if ( $key eq 'comment' ) {
                    push @{ $tables{ $table_name }{'comments'} }, $value;
                }
                else {
                    push @{ $tables{ $table_name }{'table_options'} }, $option;
                }
            }
        }

        1;
    }

opt_if_not_exists : /if not exists/i

create : CREATE UNIQUE(?) /(index|key)/i index_name /on/i table_name '(' field_name(s /,/) ')' "$delimiter"
    {
        @table_comments = ();
        push @{ $tables{ $item{'table_name'} }{'indices'} },
            {
                name   => $item[4],
                type   => $item[2] ? 'unique' : 'normal',
                fields => $item[8],
            }
        ;
    }

create_definition : constraint 
    | index
    | field
    | comment
    | <error>

comment : /^\s*(?:#|-{2}).*\n/ 
    { 
        my $comment =  $item[1];
        $comment    =~ s/^\s*(#|--)\s*//;
        $comment    =~ s/\s*$//;
        $return     = $comment;
    }

comment : /\/\*/ /.*?\*\//s
    {
        my $comment = $item[2];
        $comment = substr($comment, 0, -2);
        $comment    =~ s/^\s*|\s*$//g;
        $return = $comment;
    }
    
field_comment : /^\s*(?:#|-{2}).*\n/ 
    { 
        my $comment =  $item[1];
        $comment    =~ s/^\s*(#|--)\s*//;
        $comment    =~ s/\s*$//;
        $return     = $comment;
    }


field_comment2 : /comment/i /'.*?'/
    {
        my $comment = $item[2];
        $comment    =~ s/^'//;
        $comment    =~ s/'$//;
        $return     = $comment;
    }

blank : /\s*/

field : field_comment(s?) field_name data_type field_qualifier(s?) field_comment2(?) reference_definition(?) on_update(?) field_comment(s?)
    { 
        my %qualifiers  = map { %$_ } @{ $item{'field_qualifier(s?)'} || [] };
        if ( my @type_quals = @{ $item{'data_type'}{'qualifiers'} || [] } ) {
            $qualifiers{ $_ } = 1 for @type_quals;
        }

        my $null = defined $qualifiers{'not_null'} 
                   ? $qualifiers{'not_null'} : 1;
        delete $qualifiers{'not_null'};

        my @comments = ( @{ $item[1] }, @{ $item[5] }, @{ $item[8] } );

        $return = { 
            supertype   => 'field',
            name        => $item{'field_name'}, 
            data_type   => $item{'data_type'}{'type'},
            size        => $item{'data_type'}{'size'},
            list        => $item{'data_type'}{'list'},
            null        => $null,
            constraints => $item{'reference_definition(?)'},
            comments    => [ @comments ],
            %qualifiers,
        } 
    }
    | <error>

field_qualifier : not_null
    { 
        $return = { 
             null => $item{'not_null'},
        } 
    }

field_qualifier : default_val
    { 
        $return = { 
             default => $item{'default_val'},
        } 
    }

field_qualifier : auto_inc
    { 
        $return = { 
             is_auto_inc => $item{'auto_inc'},
        } 
    }

field_qualifier : primary_key
    { 
        $return = { 
             is_primary_key => $item{'primary_key'},
        } 
    }

field_qualifier : unsigned
    { 
        $return = { 
             is_unsigned => $item{'unsigned'},
        } 
    }

field_qualifier : /character set/i WORD 
    {
        $return = {
            'CHARACTER SET' => $item[2],
        }
    }

field_qualifier : /collate/i WORD
    {
        $return = {
            COLLATE => $item[2],
        }
    }

field_qualifier : /on update/i CURRENT_TIMESTAMP
    {
        $return = {
            'ON UPDATE' => $item[2],
        }
    }

field_qualifier : /unique/i KEY(?)
    {
        $return = {
            is_unique => 1,
        }
    }

field_qualifier : KEY
    {
        $return = {
            has_index => 1,
        }
    }

reference_definition : /references/i table_name parens_field_list(?) match_type(?) on_delete(?) on_update(?)
    {
        $return = {
            type             => 'foreign_key',
            reference_table  => $item[2],
            reference_fields => $item[3][0],
            match_type       => $item[4][0],
            on_delete        => $item[5][0],
            on_update        => $item[6][0],
        }
    }

match_type : /match full/i { 'full' }
    |
    /match partial/i { 'partial' }

on_delete : /on delete/i reference_option
    { $item[2] }

on_update : 
    /on update/i 'CURRENT_TIMESTAMP'
    { $item[2] }
    |
    /on update/i reference_option
    { $item[2] }

reference_option: /restrict/i | 
    /cascade/i   | 
    /set null/i  | 
    /no action/i | 
    /set default/i
    { $item[1] }  

index : normal_index
    | fulltext_index
    | <error>

table_name   : NAME

field_name   : NAME

index_name   : NAME

data_type    : WORD parens_value_list(s?) type_qualifier(s?)
    { 
        my $type = $item[1];
        my $size; # field size, applicable only to non-set fields
        my $list; # set list, applicable only to sets (duh)

        if ( uc($type) =~ /^(SET|ENUM)$/ ) {
            $size = undef;
            $list = $item[2][0];
        }
        else {
            $size = $item[2][0];
            $list = [];
        }

        unless ( @{ $size || [] } ) {
            if ( lc $type eq 'tinyint' ) {
                $size = 4;
            }
            elsif ( lc $type eq 'smallint' ) {
                $size = 6;
            }
            elsif ( lc $type eq 'mediumint' ) {
                $size = 9;
            }
            elsif ( $type =~ /^int(eger)?$/i ) {
                $type = 'int';
                $size = 11;
            }
            elsif ( lc $type eq 'bigint' ) {
                $size = 20;
            }
            elsif ( 
                lc $type =~ /(float|double|decimal|numeric|real|fixed|dec)/ 
            ) {
                $size = [8,2];
            }
        }

        if ( $type =~ /^tiny(text|blob)$/i ) {
            $size = 255;
        }
        elsif ( $type =~ /^(blob|text)$/i ) {
            $size = 65_535;
        }
        elsif ( $type =~ /^medium(blob|text)$/i ) {
            $size = 16_777_215;
        }
        elsif ( $type =~ /^long(blob|text)$/i ) {
            $size = 4_294_967_295;
        }

        $return        = { 
            type       => $type,
            size       => $size,
            list       => $list,
            qualifiers => $item[3],
        } 
    }

parens_field_list : '(' field_name(s /,/) ')'
    { $item[2] }

parens_value_list : '(' VALUE(s /,/) ')'
    { $item[2] }

type_qualifier : /(BINARY|UNSIGNED|ZEROFILL)/i
    { lc $item[1] }

field_type   : WORD

create_index : /create/i /index/i

not_null     : /not/i /null/i 
    { $return = 0 }
    |
    /null/i
    { $return = 1 }

unsigned     : /unsigned/i { $return = 0 }

#default_val  : /default/i /(?:')?[\s\w\d:.-]*(?:')?/ 
#    { 
#        $item[2] =~ s/'//g; 
#        $return  =  $item[2];
#    }

default_val : 
    /default/i 'CURRENT_TIMESTAMP'
    {
        $return =  $item[2];
    }
    |
    /default/i /'(?:.*?\\')*.*?'|(?:')?[\w\d:.-]*(?:')?/
    {
        $item[2] =~ s/^\s*'|'\s*$//g;
        $return  =  $item[2];
    }

auto_inc : /auto_increment/i { 1 }

primary_key : /primary/i /key/i { 1 }

constraint : primary_key_def
    | unique_key_def
    | foreign_key_def
    | <error>

foreign_key_def : foreign_key_def_begin parens_field_list reference_definition
    {
        $return              =  {
            supertype        => 'constraint',
            type             => 'foreign_key',
            name             => $item[1],
            fields           => $item[2],
            %{ $item{'reference_definition'} },
        }
    }

foreign_key_def_begin : /constraint/i /foreign key/i WORD
    { $return = $item[3] }
    |
    /constraint/i NAME /foreign key/i
    { $return = $item[2] }
    |
    /constraint/i /foreign key/i
    { $return = '' }
    |
    /foreign key/i WORD
    { $return = $item[2] }
    |
    /foreign key/i
    { $return = '' }

primary_key_def : primary_key index_name(?) '(' name_with_opt_paren(s /,/) ')'
    { 
        $return       = { 
            supertype => 'constraint',
            name      => $item{'index_name(?)'}[0],
            type      => 'primary_key',
            fields    => $item[4],
        };
    }

unique_key_def : UNIQUE KEY(?) index_name(?) '(' name_with_opt_paren(s /,/) ')'
    { 
        $return       = { 
            supertype => 'constraint',
            name      => $item{'index_name(?)'}[0],
            type      => 'unique',
            fields    => $item[5],
        } 
    }

normal_index : KEY index_name(?) '(' name_with_opt_paren(s /,/) ')'
    { 
        $return       = { 
            supertype => 'index',
            type      => 'normal',
            name      => $item{'index_name(?)'}[0],
            fields    => $item[4],
        } 
    }

fulltext_index : /fulltext/i KEY(?) index_name(?) '(' name_with_opt_paren(s /,/) ')'
    { 
        $return       = { 
            supertype => 'index',
            type      => 'fulltext',
            name      => $item{'index_name(?)'}[0],
            fields    => $item[5],
        } 
    }

name_with_opt_paren : NAME parens_value_list(s?)
    { $item[2][0] ? "$item[1]($item[2][0][0])" : $item[1] }

UNIQUE : /unique/i { 1 }

KEY : /key/i | /index/i

table_option : /comment/i /=/ /'.*?'/
    {
        my $comment = $item[3];
        $comment    =~ s/^'//;
        $comment    =~ s/'$//;
        $return     = { comment => $comment };
    }
    | /(default )?(charset|character set)/i /\s*=\s*/ WORD
    { 
        $return = { 'CHARACTER SET' => $item[3] };
    }
    | WORD /\s*=\s*/ WORD
    { 
        $return = { $item[1] => $item[3] };
    }
    
default : /default/i

ADD : /add/i

ALTER : /alter/i

CREATE : /create/i

TEMPORARY : /temporary/i

TABLE : /table/i

WORD : /\w+/

DIGITS : /\d+/

COMMA : ','

NAME    : "`" /\w+/ "`"
    { $item[2] }
    | /\w+/
    { $item[1] }

VALUE   : /[-+]?\.?\d+(?:[eE]\d+)?/
    { $item[1] }
    | /'.*?'/   
    { 
        # remove leading/trailing quotes 
        my $val = $item[1];
        $val    =~ s/^['"]|['"]$//g;
        $return = $val;
    }
    | /NULL/
    { 'NULL' }

CURRENT_TIMESTAMP : /current_timestamp(\(\))?/i
	| /now\(\)/i
	{ 'CURRENT_TIMESTAMP' }
	
END_OF_GRAMMAR

# -------------------------------------------------------------------
sub parse {
    my ( $translator, $data ) = @_;
    my $parser = Parse::RecDescent->new($GRAMMAR);

    local $::RD_TRACE  = $translator->trace ? 1 : undef;
    local $DEBUG       = $translator->debug;

    unless (defined $parser) {
        return $translator->error("Error instantiating Parse::RecDescent ".
            "instance: Bad grammer");
    }

    my $result = $parser->startrule($data);
    return $translator->error( "Parse failed." ) unless defined $result;
    warn "Parse result:".Dumper( $result ) if $DEBUG;

    my $schema = $translator->schema;
    $schema->name($result->{'database_name'}) if $result->{'database_name'};

    my @tables = sort { 
        $result->{'tables'}{ $a }{'order'} 
        <=> 
        $result->{'tables'}{ $b }{'order'}
    } keys %{ $result->{'tables'} };

    for my $table_name ( @tables ) {
        my $tdata =  $result->{tables}{ $table_name };
        my $table =  $schema->add_table( 
            name  => $tdata->{'table_name'},
        ) or die $schema->error;

        $table->comments( $tdata->{'comments'} );

        my @fields = sort { 
            $tdata->{'fields'}->{$a}->{'order'} 
            <=>
            $tdata->{'fields'}->{$b}->{'order'}
        } keys %{ $tdata->{'fields'} };

        for my $fname ( @fields ) {
            my $fdata = $tdata->{'fields'}{ $fname };
            my $field = $table->add_field(
                name              => $fdata->{'name'},
                data_type         => $fdata->{'data_type'},
                size              => $fdata->{'size'},
                default_value     => $fdata->{'default'},
                is_auto_increment => $fdata->{'is_auto_inc'},
                is_nullable       => $fdata->{'null'},
                comments          => $fdata->{'comments'},
            ) or die $table->error;

            $table->primary_key( $field->name ) if $fdata->{'is_primary_key'};

            for my $qual ( qw[ binary unsigned zerofill list collate ],
            		'character set', 'on update' ) {
                if ( my $val = $fdata->{ $qual } || $fdata->{ uc $qual } ) {
                    next if ref $val eq 'ARRAY' && !@$val;
                    $field->extra( $qual, $val );
                }
            }

            if ( $fdata->{'has_index'} ) {
                $table->add_index(
                    name   => '',
                    type   => 'NORMAL',
                    fields => $fdata->{'name'},
                ) or die $table->error;
            }

            if ( $fdata->{'is_unique'} ) {
                $table->add_constraint(
                    name   => '',
                    type   => 'UNIQUE',
                    fields => $fdata->{'name'},
                ) or die $table->error;
            }

            if ( $field->data_type =~ /(set|enum)/i && !$field->size ) {
                my %extra = $field->extra;
                my $longest = 0;
                for my $len ( map { length } @{ $extra{'list'} || [] } ) {
                    $longest = $len if $len > $longest;
                }
                $field->size( $longest ) if $longest;
            }

            for my $cdata ( @{ $fdata->{'constraints'} } ) {
                next unless $cdata->{'type'} eq 'foreign_key';
                $cdata->{'fields'} ||= [ $field->name ];
                push @{ $tdata->{'constraints'} }, $cdata;
            }
        }

        for my $idata ( @{ $tdata->{'indices'} || [] } ) {
            my $index  =  $table->add_index(
                name   => $idata->{'name'},
                type   => uc $idata->{'type'},
                fields => $idata->{'fields'},
            ) or die $table->error;
        }

        if ( my @options = @{ $tdata->{'table_options'} || [] } ) {
            $table->options( \@options ) or die $table->error;
        }

        for my $cdata ( @{ $tdata->{'constraints'} || [] } ) {
            my $constraint       =  $table->add_constraint(
                name             => $cdata->{'name'},
                type             => $cdata->{'type'},
                fields           => $cdata->{'fields'},
                reference_table  => $cdata->{'reference_table'},
                reference_fields => $cdata->{'reference_fields'},
                match_type       => $cdata->{'match_type'} || '',
                on_delete        => $cdata->{'on_delete'} || $cdata->{'on_delete_do'},
                on_update        => $cdata->{'on_update'} || $cdata->{'on_update_do'},
            ) or die $table->error;
        }
    }

    return 1;
}

1;

# -------------------------------------------------------------------
# Where man is not nature is barren.
# William Blake
# -------------------------------------------------------------------

=pod

=head1 AUTHOR

Ken Youens-Clark E<lt>kclark@cpan.orgE<gt>,
Chris Mungall E<lt>cjm@fruitfly.orgE<gt>.

=head1 SEE ALSO

Parse::RecDescent, SQL::Translator::Schema.

=cut
