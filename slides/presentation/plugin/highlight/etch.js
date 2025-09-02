/*
Language: EtchLang
Description: Syntax highlighting for the Etch programming language
Author: Claude Code
Category: system
*/

(function() {
  'use strict';

  window.etchLang = function(hljs) {
    const KEYWORDS = [
      'and',
      'or',
      'not',
      'fn',
      'let',
      'var',
      'while',
      'for',
      'in',
      'break',
      'if',
      'else',
      'match',
      'return',
      'defer',
      'discard',
      'comptime',
      'type',
      'distinct',
      'object',
      'new',
      'import',
      'export',
      'ffi',
      'inject'
    ];

    const TYPES = [
      'nil',
      'void',
      'bool',
      'char',
      'int',
      'float',
      'string',
      'array',
      'ref',
      'option',
      'result'
    ];

    const BUILT_INS = [
      'print',
      'some',
      'isSome',
      'none',
      'isNone',
      'ok',
      'isOk',
      'error',
      'isError',
      'arrayNew',
      'parseBool',
      'parseInt',
      'parseFloat',
      'toString',
      'seed',
      'rand',
      'readFile'
    ];

    return {
      name: 'EtchLang',
      aliases: ['etch', 'etchlang'],
      keywords: {
        keyword: KEYWORDS.join(' '),
        literal: 'true false'
      },
      contains: [
        // Line comments
        hljs.COMMENT('//', '$'),
        // Block comments
        hljs.COMMENT(
          '/\\*',
          '\\*/',
          {
            contains: ['self']
          }
        ),
        // Strings
        {
          className: 'string',
          begin: '"',
          end: '"',
          contains: [
            {
              className: 'subst',
              begin: '\\\\.',
              relevance: 0
            }
          ]
        },
        // Length operator #
        {
          className: 'keyword',
          begin: '#',
          relevance: 0
        },
        // Numbers
        {
          className: 'number',
          variants: [
            { begin: '\\b\\d+\\.\\d+' }, // Float
            { begin: '\\b\\d+' }         // Integer
          ],
          relevance: 0
        },
        // Built-in functions - must come before function definitions
        {
          className: 'built_in',
          begin: '\\b(' + BUILT_INS.join('|') + ')\\b'
        },
        // Types - explicit pattern for different color
        {
          className: 'type',
          begin: '\\b(' + TYPES.join('|') + ')\\b'
        },
        // Function definitions
        {
          className: 'function',
          beginKeywords: 'fn',
          end: /\{/,
          excludeEnd: true,
          contains: [
            {
              className: 'title',
              begin: /[a-zA-Z_][a-zA-Z0-9_]*/,
              relevance: 0
            },
            {
              className: 'params',
              begin: /\(/,
              end: /\)/,
              contains: [
                'self',
                hljs.COMMENT('//', '$'),
                hljs.COMMENT('/\\*', '\\*/'),
                // Types inside parameters
                {
                  className: 'type',
                  begin: '\\b(' + TYPES.join('|') + ')\\b'
                }
              ]
            }
          ]
        }
      ]
    };
  };
})();
